import AppKit
import Foundation

/// Drives everything: keeps the candidate pool topped up, picks the next
/// wallpaper, renders it, sets it, and remembers where it has been.
@MainActor
final class Rotator {

    private(set) var settings: Settings
    private var library: ImageLibrary
    private let generations: GenerationStore

    private(set) var history: [URL] = []
    private var historyIndex: Int = -1
    private(set) var current: URL?
    private(set) var currentOrigin: RemoteImage?
    /// Effect applied to the current wallpaper. Held so a clock tick redraws
    /// with the same effect rather than reshuffling every minute.
    private var currentEffect: Filter?

    private var rotationTimer: Timer?
    private var clockTimer: Timer?
    private var quoteTimer: Timer?
    private var currentQuote: Quote?
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
        scheduleQuoteChange()

        if settings.changeOnWake {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(didWake),
                name: NSWorkspace.didWakeNotification, object: nil)
        }

        Task {
            await refillIfNeeded()
            if settings.changeOnStart { await next() }
        }
    }

    @objc private func didWake() { Task { await next() } }

    func scheduleRotation() {
        rotationTimer?.invalidate()
        guard settings.changeEnabled, settings.changeInterval > 0 else { return }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: settings.changeInterval,
                                             repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.next() }
        }
    }

    /// The clock redraws the same photo with a new time. Because WallpaperAgent
    /// caches by URL, each tick still produces a new file.
    private func scheduleClock() {
        clockTimer?.invalidate()
        guard settings.clockEnabled, settings.changeEnabled else { return }

        // Fire on the minute boundary so the displayed time is never stale.
        let now = Date()
        let nextMinute = Calendar.current.nextDate(
            after: now, matching: DateComponents(second: 0),
            matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)

        clockTimer = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.redrawCurrent() }
        }
        RunLoop.main.add(clockTimer!, forMode: .common)
    }

    /// Variety can rotate the quote independently of the wallpaper.
    private func scheduleQuoteChange() {
        quoteTimer?.invalidate()
        guard settings.quotesEnabled, settings.quotesChangeEnabled,
              settings.quotesChangeInterval > 0 else { return }

        quoteTimer = Timer.scheduledTimer(withTimeInterval: settings.quotesChangeInterval,
                                          repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentQuote = await self.nextQuote()
                await self.redrawCurrent()
            }
        }
    }

    func applySettings(_ new: Settings) {
        let foldersChanged = new.downloadFolder != settings.downloadFolder
            || new.favoritesFolder != settings.favoritesFolder
            || new.fetchedFolder != settings.fetchedFolder

        settings = new
        try? new.save()
        if foldersChanged { library = ImageLibrary(settings: new) }

        scheduleRotation()
        scheduleClock()
        scheduleQuoteChange()
    }

    var isPaused: Bool { !settings.changeEnabled }

    func setPaused(_ paused: Bool) {
        settings.changeEnabled = !paused
        applySettings(settings)
    }

    // MARK: - Navigation

    func next() async {
        await refillIfNeeded()

        if historyIndex >= 0, historyIndex < history.count - 1 {
            historyIndex += 1
            await show(history[historyIndex], recordHistory: false, newEffect: true)
            return
        }

        guard let pick = pickNext() else { return }
        await show(pick, recordHistory: true, newEffect: true)
    }

    /// Variety biases towards freshly downloaded images over the local pool via
    /// `download_preference_ratio`.
    private func pickNext() -> URL? {
        let downloaded = library.downloaded()
        let local = SourceRegistry.activeLocalFiles(settings: settings)

        if !downloaded.isEmpty, !local.isEmpty {
            return Double.random(in: 0...1) < settings.downloadPreferenceRatio
                ? downloaded.randomElement()
                : local.randomElement()
        }
        return downloaded.randomElement() ?? local.randomElement()
    }

    func previous() async {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        await show(history[historyIndex], recordHistory: false, newEffect: false)
    }

    func redrawCurrent() async {
        guard let current else { return }
        await show(current, recordHistory: false, newEffect: false)
    }

    func show(file: URL) async {
        await show(file, recordHistory: true, newEffect: true)
    }

    // MARK: - Applying

    private func show(_ file: URL, recordHistory: Bool, newEffect: Bool) async {
        let target = Self.targetSize()

        if newEffect {
            currentEffect = EffectRenderer.randomEnabled(from: settings.filters)
        }
        if settings.quotesEnabled, currentQuote == nil {
            currentQuote = await nextQuote()
        }

        let mode = DisplayMode(rawValue: settings.wallpaperDisplayMode) ?? .os
        let destination = generations.nextURL(ext: "jpg")

        let request = ImagePipeline.Request(
            source: file,
            targetSize: target,
            mode: mode,
            quote: settings.quotesEnabled ? currentQuote : nil,
            clockDate: settings.clockEnabled ? Date() : nil,
            settings: settings,
            effect: currentEffect
        )

        do {
            try ImagePipeline.render(request, to: destination)
            try WallpaperSetter.apply(url: destination)

            current = file
            currentOrigin = library.metadata(for: file)
            if recordHistory {
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

    private func nextQuote() async -> Quote? {
        await QuoteProvider.random(settings: settings)
    }

    private static func targetSize() -> CGSize {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return CGSize(width: 2560, height: 1600) }
        return screens.map { screen -> CGSize in
            let scale = screen.backingScaleFactor
            return CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        }.max { $0.width * $0.height < $1.width * $1.height }!
    }

    // MARK: - Browsing

    func favoritesForDisplay() -> [URL] { library.favorites() }
    func recentForDisplay() -> [URL] { library.downloaded() }
    func fetchedForDisplay() -> [URL] { library.fetched() }
    var historyForDisplay: [URL] { history.reversed() }

    /// Everything the Wallpaper Selector can offer.
    func allSelectable() -> [URL] {
        library.favorites() + library.downloaded() + library.fetched()
            + SourceRegistry.activeLocalFiles(settings: settings)
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

    var currentIsFavorite: Bool { current.map { library.isFavorite($0) } ?? false }

    func revealCurrent() {
        guard let current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([current])
    }

    func openCurrentOrigin() {
        guard let url = currentOrigin?.originURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Copies the current wallpaper somewhere the user chooses — Variety's
    /// "Save to" / copyto behaviour.
    func copyCurrent(to folder: URL) {
        guard let current else { return }
        let destination = folder.appendingPathComponent(current.lastPathComponent)
        try? FileManager.default.copyItem(at: current, to: destination)
    }

    var downloadedBytes: Int64 { library.downloadedBytes }

    // MARK: - Fetching

    func refillIfNeeded(minimum: Int = 30) async {
        guard !fetching else { return }
        guard settings.internetEnabled else { return }
        guard library.downloaded().count < minimum else { return }
        fetching = true
        defer { fetching = false }

        let downloaders = SourceRegistry.activeDownloaders(settings: settings)
        guard !downloaders.isEmpty else { return }

        let candidates: [RemoteImage] = await withTaskGroup(of: [RemoteImage].self) { group in
            for source in downloaders {
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

        let screen = Self.targetSize()

        // Reject on the dimensions the service reported, before spending any
        // bandwidth — this is what makes "only images that fit my screen"
        // actually cheap. Sources that report no size fall through and get
        // checked against the file after download instead.
        let fitting = candidates.filter { $0.fitsScreen(settings: settings) }

        // Then prefer the ones whose shape matches the screen, so the crop
        // throws away as little as possible. Sampled rather than strictly
        // ordered, or every refill would return the same images.
        let ranked = fitting
            .map { (image: $0, score: $0.aspectMatch * Double.random(in: 0.75...1.0)) }
            .sorted { $0.score > $1.score }
            .map(\.image)

        if fitting.count < candidates.count {
            NSLog("VarietyV2: \(candidates.count - fitting.count) of \(candidates.count) candidates rejected as too small or wrong shape for \(Int(screen.width))×\(Int(screen.height))")
        }

        for image in ranked.prefix(40) {
            do { try await library.download(image, screenSize: screen) }
            catch { NSLog("VarietyV2: download failed for \(image.id): \(error)") }
        }
        library.enforceQuota()
    }
}
