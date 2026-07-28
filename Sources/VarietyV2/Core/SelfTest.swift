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
        wallhavenPhrasesBecomeTags()
        wallhavenRelaxationLadder()
        preparedBufferCoversEverythingBeforeRepeating()
        donationDetailsAreUpstream()

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

    /// Wallhaven matches a bare multi-word query as one exact tag, so a typed
    /// phrase returns nothing at all. Measured: "real dark forest" gives 0
    /// results, "+real +dark +forest" gives ~2,800.
    private static func wallhavenPhrasesBecomeTags() {
        let t = WallhavenSource.tagQuery

        check("a phrase becomes an AND of tags",
              t("real dark forest") == "+real +dark +forest")
        check("a single word is left alone",
              t("forest") == "forest")
        check("surrounding whitespace is trimmed",
              t("  misty forest  ") == "+misty +forest")

        // Anything already using Wallhaven's syntax must pass through, or the
        // translation would corrupt deliberate queries.
        check("existing + syntax is preserved", t("+dark +forest") == "+dark +forest")
        check("exclusions are preserved", t("-anime forest") == "-anime forest")
        check("quoted phrases are preserved", t("\"dark forest\"") == "\"dark forest\"")
        check("id: and like: lookups are preserved", t("id:123") == "id:123")
        check("@username is preserved", t("@someone") == "@someone")
        check("an empty query stays empty", t("") == "")
    }

    /// A failed phrase must broaden rather than return nothing.
    private static func wallhavenRelaxationLadder() {
        let ladder = WallhavenSource.relaxations(of: "real dark forest")
        check("a phrase relaxes by dropping leading words",
              ladder == ["+real +dark +forest", "+dark +forest", "+forest"])

        check("a single word has nothing to relax",
              WallhavenSource.relaxations(of: "forest") == ["forest"])

        // Deliberate operator syntax must not be broadened behind the user's
        // back — an exclusion silently dropped would change what they asked for.
        check("operator syntax is not relaxed",
              WallhavenSource.relaxations(of: "-anime forest") == ["-anime forest"])
    }

    /// The property that makes a rotation feel unsupervised: every image is
    /// shown once before any is shown twice.
    ///
    /// Random sampling — the previous behaviour — fails this badly. With 40
    /// images, drawing at random needs about 170 draws to cover them all, and
    /// some are shown five or six times before others appear at all. Consuming
    /// from a shuffled buffer covers them in exactly 40.
    private static func preparedBufferCoversEverythingBeforeRepeating() {
        // Mirrors Rotator's buffer discipline.
        struct Buffer {
            var pool: [Int]
            var prepared: [Int] = []
            var current: Int?

            mutating func next() -> Int? {
                let threshold = min(10, max(1, pool.count / 2))
                if prepared.count <= threshold {
                    let queued = Set(prepared)
                    prepared.append(contentsOf: pool.filter { !queued.contains($0) }.shuffled())
                }
                while !prepared.isEmpty {
                    let candidate = prepared.removeFirst()
                    if candidate != current { current = candidate; return candidate }
                }
                return nil
            }
        }

        let poolSize = 40
        var buffer = Buffer(pool: Array(0..<poolSize))

        var counts: [Int: Int] = [:]
        for _ in 0..<poolSize {
            guard let picked = buffer.next() else { break }
            counts[picked, default: 0] += 1
        }

        check("every image appears within one pass of the library",
              counts.keys.count == poolSize)
        check("no image repeats before the pass completes",
              counts.values.allSatisfy { $0 == 1 })

        // Beyond the first pass the buffer is topped up before it empties, so
        // images already shown are reintroduced and repeats become possible —
        // that is true of Variety too, and is the point of a *rolling* buffer
        // rather than strict epochs. What matters is that it never stalls and
        // stays well spread.
        var later: [Int] = []
        for _ in 0..<(poolSize * 3) {
            guard let picked = buffer.next() else { break }
            later.append(picked)
        }
        check("rotation never stalls after the first pass",
              later.count == poolSize * 3)
        check("continued rotation still spans the library",
              Set(later).count == poolSize)

        // The property that actually prevents the "same few images" feeling:
        // no image dominates.
        let tally = later.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
        let mostFrequent = tally.values.max() ?? 0
        check("no image is over-represented (max \(mostFrequent) of 3 expected)",
              mostFrequent <= 6)
    }

    /// The donation destinations must stay exactly as upstream publishes them.
    ///
    /// Worth a test purely because of the consequence of being wrong: a typo
    /// here does not fail loudly, it quietly sends someone's money somewhere
    /// else. Values are from `VarietyWindow.DONATE_URL` and the
    /// `donate_bitcoin_address` field in Variety's preferences UI.
    private static func donationDetailsAreUpstream() {
        let url = DonateTab.payPalURL.absoluteString
        check("PayPal recipient is Variety's own",
              url.contains("business=DHQUELMQRQW46"))
        check("PayPal donation is labelled and denominated as upstream",
              url.contains("item_name=Variety+Wallpaper+Changer")
                  && url.contains("currency_code=EUR"))
        check("PayPal link points at paypal.com",
              DonateTab.payPalURL.host == "www.paypal.com")
        check("Bitcoin wallet matches upstream",
              DonateTab.bitcoinAddress == "bc1qgxlvmwe2pj5lvku6vm53edes3q7c3ykta7xyu4")
    }

    // MARK: -

    private static func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("varietyv2-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
