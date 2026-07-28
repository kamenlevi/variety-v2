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
    private var lastRefill: Date?
    /// Identifies the enabled source set, so adding or editing one forces a
    /// fetch instead of waiting for the pool to drain.
    private var lastSourceSignature: String?
    /// The rendered file currently on screen — the starting point for a fade.
    private var lastShownGeneration: URL?

    var onChange: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
        self.library = ImageLibrary(settings: settings)
        // Retention has to clear a whole fade plus the previous wallpaper: a
        // slow fade writes ten frames and a destination, and if the outgoing
        // image is pruned in that flurry the *next* fade has nothing to start
        // from and silently falls back to a hard cut.
        self.generations = GenerationStore(
            directory: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/VarietyV2/generated"),
            retain: 24)

        // Restore what was showing and where the user had browsed to. Without
        // this the menu has no image section until the first rotation, and
        // History is empty on every launch.
        let state = RotationState.load()
        history = state.history.map { URL(fileURLWithPath: $0) }
        historyIndex = min(state.index, history.count - 1)
        current = state.current.map { URL(fileURLWithPath: $0) }
        currentOrigin = current.flatMap { library.metadata(for: $0) }
    }

    private func persistState() {
        RotationState(
            history: history.suffix(RotationState.maxHistory).map(\.path),
            index: min(historyIndex, history.count - 1),
            current: current?.path
        ).save()
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

    /// When the next automatic change is due, or nil when rotation is off.
    /// Surfaced so Preferences can show a countdown — the quickest way to tell
    /// whether the interval setting actually took effect.
    private(set) var nextChangeDate: Date?

    func scheduleRotation() {
        rotationTimer?.invalidate()
        nextChangeDate = nil
        guard settings.changeEnabled, settings.changeInterval > 0 else { return }

        nextChangeDate = Date().addingTimeInterval(settings.changeInterval)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: settings.changeInterval,
                                             repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.nextChangeDate = Date().addingTimeInterval(self.settings.changeInterval)
                await self.next()
            }
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
        let sourcesChanged = new.sources != settings.sources

        settings = new
        try? new.save()
        if foldersChanged { library = ImageLibrary(settings: new) }

        scheduleRotation()
        scheduleClock()
        scheduleQuoteChange()

        // Turning on a source or adding a search should fetch from it now,
        // not whenever the pool next happens to run down.
        if sourcesChanged || foldersChanged {
            invalidatePrepared()
            Task { await refillIfNeeded(force: true) }
        }
    }

    /// The enabled sources, as a value that changes whenever they do.
    private func sourceSignature() -> String {
        settings.sources
            .filter(\.enabled)
            .map(\.id)
            .sorted()
            .joined(separator: ";")
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

    /// A shuffled buffer of images not yet shown this pass.
    ///
    /// This is Variety's `prepared` list, and the reason its rotation feels
    /// like something you never have to think about. Images are *consumed*
    /// from the buffer rather than sampled at random each time, so everything
    /// eligible is shown once before anything repeats. Random sampling — which
    /// is what this did before — repeats images constantly and can leave parts
    /// of a library unseen indefinitely, which is what makes a rotation feel
    /// like it needs supervising.
    private var prepared: [URL] = []

    /// Refill when the buffer runs low, as Variety does at
    /// `min(10, image_count // 2)`.
    private func refillPreparedIfNeeded() {
        let pool = eligiblePool()
        let threshold = min(10, max(1, pool.count / 2))
        guard prepared.count <= threshold else { return }

        // Everything not already queued, reshuffled. Excluding what is still
        // pending stops a refill from re-adding images about to be shown.
        let queued = Set(prepared.map(\.path))
        var fresh = pool.filter { !queued.contains($0.path) }
        fresh.shuffle()
        prepared.append(contentsOf: fresh)
    }

    /// Every image the enabled sources currently offer.
    private func eligiblePool() -> [URL] {
        var pool = library.downloaded()
        pool += SourceRegistry.activeLocalFiles(settings: settings)
        var seen = Set<String>()
        return pool.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Takes the next image from the buffer.
    ///
    /// Before drawing, and with probability `downloadPreferenceRatio`, a random
    /// unseen download jumps the queue — Variety inserts one at position 0 for
    /// the same reason: something just fetched should appear soon rather than
    /// waiting behind everything already on disk.
    private func pickNext() -> URL? {
        refillPreparedIfNeeded()

        if Double.random(in: 0...1) < settings.downloadPreferenceRatio {
            let unseen = library.unseenFiles().filter { $0 != current }
            if let jumper = unseen.randomElement() {
                prepared.removeAll { $0 == jumper }
                prepared.insert(jumper, at: 0)
            }
        }

        while !prepared.isEmpty {
            let candidate = prepared.removeFirst()
            guard candidate != current,
                  FileManager.default.isReadableFile(atPath: candidate.path)
            else { continue }
            return candidate
        }

        // Buffer exhausted and nothing refillable — fall back to anything at
        // all rather than leaving the wallpaper stuck.
        return eligiblePool().first { $0 != current }
    }

    /// Called when the source list or folders change: the buffer describes the
    /// old configuration and would keep serving from it.
    private func invalidatePrepared() { prepared.removeAll() }

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

            // Crossfade from what is on screen, when asked for.
            let fadeFrames = Crossfade.renderFrames(
                from: lastShownGeneration, to: destination, size: target,
                speed: settings.wallpaperFade, store: generations)

            for frame in fadeFrames {
                try? WallpaperSetter.apply(url: frame)
                try? await Task.sleep(for: .seconds(settings.wallpaperFade.frameInterval))
            }

            try WallpaperSetter.apply(url: destination)
            lastShownGeneration = destination

            current = file
            currentOrigin = library.metadata(for: file)
            // It has now been seen, which frees its source to fetch another.
            library.markSeen(file)
            if recordHistory {
                if historyIndex < history.count - 1 {
                    history.removeSubrange((historyIndex + 1)...)
                }
                history.append(file)
                historyIndex = history.count - 1
            }
            generations.collect(keeping: destination)
            persistState()
            onChange?()
            // Variety triggers a download a couple of seconds after each
            // change, so fetching happens in the gaps rather than in bursts.
            topUpInBackground()
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

    /// Everything the enabled sources currently offer — what the Wallpaper
    /// Selector lists.
    func selectableFromSources() -> [URL] {
        var files = library.favorites() + library.downloaded() + library.fetched()
        files += SourceRegistry.activeLocalFiles(settings: settings)
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
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

    // MARK: - Bulk removal

    func downloadCountsBySource() -> [(source: String, count: Int, bytes: Int64)] {
        library.downloadCountsBySource()
    }

    /// Clears downloads, then makes sure the desktop is not still showing one
    /// of the images that was just removed.
    @discardableResult
    func clearDownloads(source: String? = nil) async -> Int {
        let removed = library.clearDownloads(source: source)
        history.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        historyIndex = min(historyIndex, history.count - 1)

        if let current, !FileManager.default.fileExists(atPath: current.path) {
            self.current = nil
            await next()
        }
        onChange?()
        return removed
    }

    @discardableResult
    func remove(_ files: [URL]) async -> Int {
        let removed = library.remove(files)
        history.removeAll { files.contains($0) }
        historyIndex = min(historyIndex, history.count - 1)

        if let current, files.contains(current) {
            self.current = nil
            await next()
        }
        onChange?()
        return removed
    }

    func resetBanished() { library.resetBanished() }
    var banishedCount: Int { library.banishedCount }

    // MARK: - Fetching

    /// How long a full pool stays fresh before topping it up anyway.
    private static let refillInterval: TimeInterval = 20 * 60

    /// Tops up the candidate pool.
    ///
    /// The condition here is deliberately *not* just "the pool is small". An
    /// earlier version guarded on `downloaded().count < minimum` alone, which
    /// meant that once the folder filled up the app stopped downloading
    /// permanently — adding a new source could never bring in anything new,
    /// and the rotation was stuck on whatever it happened to fetch first.
    ///
    /// A refill now happens when any of these is true:
    ///   - the enabled source list has changed since the last fetch
    ///   - the pool has dropped below `minimum`
    ///   - it has simply been a while
    ///   - the caller forced it
    func refillIfNeeded(force: Bool = false, minimum: Int = 30) async {
        guard !fetching else { return }
        guard settings.internetEnabled else { return }

        let signature = sourceSignature()
        let sourcesChanged = signature != lastSourceSignature
        let poolLow = library.downloaded().count < minimum
        let stale = lastRefill.map { Date().timeIntervalSince($0) >= Self.refillInterval } ?? true

        guard force || sourcesChanged || poolLow || stale else { return }

        fetching = true
        defer {
            fetching = false
            lastRefill = Date()
            lastSourceSignature = signature
        }

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

        // Keep the candidates as a queue of metadata and download sparingly.
        //
        // Variety never bulk-downloads: it fetches one image at a time and
        // stops taking from a source once that source is holding ten images
        // you have not seen yet. Grabbing forty per refill filled the folder
        // with images that would never be looked at and made every source
        // feel the same.
        queue = ranked
        await downloadFromQueue(screenSize: screen)
    }

    /// Candidate metadata waiting to be downloaded. Cheap to hold — a few
    /// hundred bytes each — and the reason downloading can be lazy.
    private var queue: [RemoteImage] = []

    /// Downloads up to `limit` images, skipping sources that already have
    /// enough unseen images waiting.
    private func downloadFromQueue(screenSize: CGSize, limit: Int = 4) async {
        var downloaded = 0

        while downloaded < limit, !queue.isEmpty {
            let image = queue.removeFirst()

            // The source id is the part of the image id before the colon.
            let sourceID = image.id.split(separator: ":").first.map(String.init) ?? image.sourceName
            guard library.unseenCount(forSource: sourceID) < ImageLibrary.maxUnseenPerSource else {
                continue
            }

            do {
                if try await library.download(image, screenSize: screenSize) != nil {
                    downloaded += 1
                }
            } catch {
                NSLog("VarietyV2: download failed for \(image.id): \(error)")
            }
        }

        library.enforceQuota()
    }

    /// Tops up in the background after a wallpaper change, as Variety does two
    /// seconds after each change, so downloading never blocks the rotation.
    private func topUpInBackground() {
        guard settings.internetEnabled, !queue.isEmpty else { return }
        Task { await downloadFromQueue(screenSize: Self.targetSize(), limit: 2) }
    }
}
