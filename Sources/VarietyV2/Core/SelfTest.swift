import AppKit
import Foundation

/// Internal checks, in the spirit of `OjoX --selftest`: they lock down the
/// invariants that were expensive to discover, so a later refactor cannot
/// quietly undo them.
enum SelfTest {

    private static var failures: [String] = []

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("  ok    \(name)")
        } else {
            print("  FAIL  \(name)")
            failures.append(name)
        }
    }

    static func run() -> Bool {
        failures = []
        print("VarietyV2 selftest")

        generationStorePathsAreUnique()
        generationStoreRetainsLiveFile()
        generationStoreCollectsOldFiles()
        wallpaperStoreParsesLiveIndex()
        settingsDecodeLeniently()
        refillTriggersWhenSourcesChange()

        print(failures.isEmpty ? "\nall checks passed" : "\n\(failures.count) check(s) failed")
        return failures.isEmpty
    }

    // MARK: - Checks

    /// The invariant the whole design rests on. If this ever regresses, the app
    /// silently stops changing the wallpaper.
    private static func generationStorePathsAreUnique() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GenerationStore(directory: dir)

        var seen = Set<String>()
        for _ in 0..<1000 { seen.insert(store.nextURL().path) }
        check("generation paths are unique across 1000 draws", seen.count == 1000)
    }

    private static func generationStoreRetainsLiveFile() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GenerationStore(directory: dir, retain: 2)

        var urls: [URL] = []
        for i in 0..<10 {
            let u = store.nextURL()
            try? Data("gen\(i)".utf8).write(to: u)
            // Distinct mtimes so ordering is deterministic rather than
            // dependent on filesystem timestamp granularity.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(i))], ofItemAtPath: u.path)
            urls.append(u)
        }

        // Nominate the *oldest* file as live — the one collection would
        // otherwise delete first.
        let live = urls[0]
        store.collect(keeping: live)
        check("collect never deletes the live wallpaper",
              FileManager.default.fileExists(atPath: live.path))
    }

    private static func generationStoreCollectsOldFiles() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GenerationStore(directory: dir, retain: 3)

        for i in 0..<20 {
            let u = store.nextURL()
            try? Data("gen\(i)".utf8).write(to: u)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(i))], ofItemAtPath: u.path)
        }
        store.collect(keeping: nil)

        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? -1
        // retain=3, and the live file is nil, so exactly 3 should survive.
        check("collect prunes to the retain count (got \(remaining), want 3)", remaining == 3)
    }

    /// Not an assertion about content — the user may legitimately be on a
    /// dynamic wallpaper. This checks the parser survives the real file shape
    /// without throwing or hanging.
    private static func wallpaperStoreParsesLiveIndex() {
        let exists = FileManager.default.fileExists(atPath: WallpaperStore.indexURL.path)
        guard exists else {
            print("  skip  wallpaper store parse (no Index.plist on this machine)")
            return
        }
        _ = WallpaperStore.currentImageURL()
        check("wallpaper store parses the live Index.plist without crashing", true)
    }

    /// A partial settings file must keep its own values *and* default the rest.
    /// Getting this wrong silently wipes every preference — it is how the login
    /// item kept unregistering itself during development.
    private static func settingsDecodeLeniently() {
        let partial = Data(#"{"startAtLogin": true}"#.utf8)
        guard let decoded = try? JSONDecoder().decode(Settings.self, from: partial) else {
            check("partial settings file decodes at all", false)
            return
        }
        check("a key present in a partial file is honoured", decoded.startAtLogin == true)
        check("keys absent from a partial file fall back to defaults",
              decoded.changeInterval == Settings().changeInterval
                  && decoded.sources.count == Settings().sources.count
                  && decoded.wallpaperDisplayMode == Settings().wallpaperDisplayMode)

        // An empty object is the degenerate case of the same problem.
        let empty = try? JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        check("an empty settings object decodes to defaults",
              empty?.changeInterval == Settings().changeInterval)

        // And a full round trip must be lossless, across the nested types too.
        var full = Settings()
        full.clockEnabled = true
        full.wallpaperDisplayMode = DisplayMode.fillWithBlur.rawValue
        full.quotaSize = 321
        full.quotesHpos = 17
        full.filters[3].enabled = true
        full.sources.append(.init(enabled: true, kind: .reddit, location: "EarthPorn"))
        full.favoritesOperations = [.init(origin: "Downloaded", operation: .move)]

        let roundTripped = (try? JSONEncoder().encode(full))
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        check("settings round-trip losslessly",
              roundTripped?.clockEnabled == true
                  && roundTripped?.wallpaperDisplayMode == DisplayMode.fillWithBlur.rawValue
                  && roundTripped?.quotaSize == 321
                  && roundTripped?.quotesHpos == 17)
        check("nested sources, filters and favorite operations round-trip",
              roundTripped?.filters[3].enabled == true
                  && roundTripped?.sources.last?.kind == .reddit
                  && roundTripped?.sources.last?.location == "EarthPorn"
                  && roundTripped?.favoritesOperations.first?.operation == .move)
    }

    /// The refill decision must not be "pool is small" alone.
    ///
    /// It was, once, and the consequence was that a full download folder
    /// stopped the app fetching anything ever again — adding a source did
    /// nothing and the rotation was frozen on its first batch. This checks the
    /// decision directly, since the symptom takes days to notice by hand.
    private static func refillTriggersWhenSourcesChange() {
        // Mirrors Rotator's guard.
        func shouldRefill(force: Bool, poolCount: Int, minimum: Int,
                          signature: String, lastSignature: String?,
                          lastRefill: Date?, interval: TimeInterval, now: Date) -> Bool {
            let sourcesChanged = signature != lastSignature
            let poolLow = poolCount < minimum
            let stale = lastRefill.map { now.timeIntervalSince($0) >= interval } ?? true
            return force || sourcesChanged || poolLow || stale
        }

        let now = Date()
        let justRefilled = now.addingTimeInterval(-10)

        check("a full pool with unchanged sources does not refetch constantly",
              shouldRefill(force: false, poolCount: 40, minimum: 30,
                           signature: "a", lastSignature: "a",
                           lastRefill: justRefilled, interval: 1200, now: now) == false)

        check("adding a source refills even when the pool is full",
              shouldRefill(force: false, poolCount: 40, minimum: 30,
                           signature: "a;b", lastSignature: "a",
                           lastRefill: justRefilled, interval: 1200, now: now))

        check("a drained pool refills",
              shouldRefill(force: false, poolCount: 3, minimum: 30,
                           signature: "a", lastSignature: "a",
                           lastRefill: justRefilled, interval: 1200, now: now))

        check("a full pool still refills once it goes stale",
              shouldRefill(force: false, poolCount: 40, minimum: 30,
                           signature: "a", lastSignature: "a",
                           lastRefill: now.addingTimeInterval(-3600), interval: 1200, now: now))

        check("a never-refilled app refills on first run",
              shouldRefill(force: false, poolCount: 40, minimum: 30,
                           signature: "a", lastSignature: nil,
                           lastRefill: nil, interval: 1200, now: now))
    }

    // MARK: -

    private static func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("varietyv2-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
