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

    // MARK: -

    private static func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("varietyv2-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
