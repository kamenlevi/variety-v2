import AppKit
import Foundation

/// Drives everything: keeps a pool of candidate images topped up, picks the
/// next wallpaper, renders it, sets it, and remembers where it has been so
/// "previous" works.
@MainActor
final class Rotator {

    private(set) var settings: Settings
    private let library: ImageLibrary
    private let generations: GenerationStore

    /// Wallpapers shown this session, newest last.
    private(set) var history: [URL] = []
    private var historyIndex: Int = -1
    private(set) var current: URL?
    private(set) var currentOrigin: RemoteImage?

    private var rotationTimer: Timer?
    private var clockTimer: Timer?
    private var fetching = false

    var onChange: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
        self.library = ImageLibrary(settings: settings)
        self.generations = GenerationStore(
            directory: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/VarietyV2/generated"))
    }

    // MARK: - Lifecycle

    func start() {
        scheduleRotation()
        scheduleClock()

        if settings.changeOnWake {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(didWake),
                name: NSWorkspace.didWakeNotification, object: nil)
        }

        Task {
            await refillIfNeeded()
            if settings.changeOnLogin { await next() }
        }
    }

    @objc private func didWake() {
        Task { await next() }
    }

    func scheduleRotation() {
        rotationTimer?.invalidate()
        guard !settings.paused, settings.changeIntervalSeconds > 0 else { return }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: settings.changeIntervalSeconds,
                                             repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.next() }
        }
    }

    /// The clock overlay re-renders the *same* photo with a new time. Because
    /// WallpaperAgent caches by URL, each tick still has to produce a new file,
    /// which is why generation GC is tuned tightly.
    private func scheduleClock() {
        clockTimer?.invalidate()
        guard settings.clockEnabled, !settings.paused else { return }

        // Fire on the minute boundary rather than 60s from now, so the
        // displayed time is never a stale minute.
        let now = Date()
        let nextMinute = Calendar.current.nextDate(
            after: now, matching: DateComponents(second: 0),
            matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)

        clockTimer = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.redrawCurrent() }
        }
        RunLoop.main.add(clockTimer!, forMode: .common)
    }

    func applySettings(_ new: Settings) {
        settings = new
        try? new.save()
        scheduleRotation()
        scheduleClock()
    }

    var isPaused: Bool { settings.paused }

    func setPaused(_ paused: Bool) {
        settings.paused = paused
        applySettings(settings)
    }

    // MARK: - Navigation

    func next() async {
        await refillIfNeeded()

        // Walking forward through history first means "previous then next"
        // retraces rather than jumping to something new.
        if historyIndex >= 0, historyIndex < history.count - 1 {
            historyIndex += 1
            await show(history[historyIndex], recordHistory: false)
            return
        }

        let pool = library.downloaded() + library.favorites()
        guard let pick = pool.randomElement() else { return }
        await show(pick, recordHistory: true)
    }

    func previous() async {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        await show(history[historyIndex], recordHistory: false)
    }

    /// Re-renders the current photo — used by the clock tick, and after a
    /// display-mode or overlay change.
    func redrawCurrent() async {
        guard let current else { return }
        await show(current, recordHistory: false)
    }

    // MARK: - Applying

    private func show(_ file: URL, recordHistory: Bool) async {
        let target = Self.targetSize()
        let quote = settings.quotesEnabled ? await QuoteProvider.random() : nil

        let destination = generations.nextURL(ext: "jpg")
        let request = ImagePipeline.Request(
            source: file,
            targetSize: target,
            mode: settings.displayMode,
            quote: quote,
            clockDate: settings.clockEnabled ? Date() : nil,
            settings: settings
        )

        do {
            try ImagePipeline.render(request, to: destination)
            try WallpaperSetter.apply(url: destination)

            current = file
            currentOrigin = library.metadata(for: file)
            if recordHistory {
                // Drop any forward history, as a browser does on navigation.
                if historyIndex < history.count - 1 {
                    history.removeSubrange((historyIndex + 1)...)
                }
                history.append(file)
                historyIndex = history.count - 1
            }
            generations.collect(keeping: destination)
            onChange?()
        } catch {
            NSLog("VarietyV2: could not show \(file.lastPathComponent): \(error)")
        }
    }

    /// Wallpapers are rendered at the largest attached screen's backing
    /// resolution so the image is sharp on Retina.
    private static func targetSize() -> CGSize {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return CGSize(width: 2560, height: 1600) }

        return screens.map { screen -> CGSize in
            let scale = screen.backingScaleFactor
            return CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        }.max { $0.width * $0.height < $1.width * $1.height }!
    }

    // MARK: - Library actions

    func favoriteCurrent() {
        guard let current, !library.isFavorite(current) else { return }
        if let moved = library.favorite(current) {
            self.current = moved
            if historyIndex >= 0, historyIndex < history.count { history[historyIndex] = moved }
            onChange?()
        }
    }

    func trashCurrent() async {
        guard let current else { return }
        library.trash(current)
        history.removeAll { $0 == current }
        historyIndex = min(historyIndex, history.count - 1)
        await next()
    }

    var currentIsFavorite: Bool {
        current.map { library.isFavorite($0) } ?? false
    }

    func revealCurrent() {
        guard let current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([current])
    }

    func openCurrentOrigin() {
        guard let url = currentOrigin?.originURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Fetching

    /// Tops the pool up when it runs low. Sources are queried concurrently and
    /// individual failures are logged rather than propagated — one dead API
    /// must not stall rotation.
    func refillIfNeeded(minimum: Int = 30) async {
        guard !fetching else { return }
        guard library.downloaded().count < minimum else { return }
        fetching = true
        defer { fetching = false }

        let enabled = SourceRegistry.all(settings: settings)
            .filter { source in settings.enabledSourceIDs.contains { source.id.hasPrefix($0) } }

        let candidates: [RemoteImage] = await withTaskGroup(of: [RemoteImage].self) { group in
            for source in enabled {
                group.addTask {
                    do { return try await source.fetch() }
                    catch {
                        NSLog("VarietyV2: source \(source.displayName) unavailable: \(error)")
                        return []
                    }
                }
            }
            var all: [RemoteImage] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }

        for image in candidates.shuffled().prefix(40) {
            do { _ = try await library.download(image) }
            catch { NSLog("VarietyV2: download failed for \(image.id): \(error)") }
        }
        library.prune()
    }
}
