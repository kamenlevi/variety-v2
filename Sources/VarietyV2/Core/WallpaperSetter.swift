import AppKit
import Foundation

/// Sets the macOS desktop wallpaper.
///
/// The important detail, established by measurement on macOS 26.5 rather than
/// from documentation: **WallpaperAgent caches the wallpaper by file URL.**
/// Writing new bytes to a path that is already the current wallpaper and
/// calling `setDesktopImageURL` again is a silent no-op — no error is thrown,
/// the store updates, and the screen does not change.
///
/// Every visual change therefore has to land on a *previously unused path*.
/// That is what `GenerationStore` exists for: it hands out a fresh filename per
/// set and garbage-collects the ones nobody is looking at any more.
///
/// A second measured quirk: `NSWorkspace.desktopImageURL(for:)` is effectively
/// dead on 26.5 — it reports `/System/Library/CoreServices/DefaultDesktop.heic`
/// regardless of what is actually on screen. `WallpaperStore` reads the real
/// state out of WallpaperAgent's own index instead.
enum WallpaperSetter {

    enum SetError: Error, CustomStringConvertible {
        case noScreens
        case failed(screen: Int, underlying: Error)

        var description: String {
            switch self {
            case .noScreens:
                return "no screens attached"
            case let .failed(screen, underlying):
                return "screen \(screen): \(underlying)"
            }
        }
    }

    /// Applies `url` to every attached screen.
    ///
    /// The caller is responsible for `url` being a path that has not been used
    /// as a wallpaper before — see `GenerationStore.nextURL(ext:)`. Passing a
    /// recycled path will appear to succeed and change nothing.
    static func apply(url: URL, scaling: NSImageScaling = .scaleProportionallyUpOrDown) throws {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw SetError.noScreens }

        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: scaling.rawValue,
            .allowClipping: true,
        ]

        // "Same image everywhere" is the chosen behaviour, so every screen gets
        // the same URL. Per-Space wallpapers are deliberately not attempted;
        // that is the corner of the API that is genuinely unreliable.
        for (index, screen) in screens.enumerated() {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            } catch {
                throw SetError.failed(screen: index, underlying: error)
            }
        }
    }
}

/// Hands out never-before-used file paths for generated wallpapers, and cleans
/// up after itself.
///
/// Sizing note: with the clock overlay enabled the app emits one file per
/// minute, so retention is a real concern rather than a theoretical one. Files
/// are kept by count, not by age, so a paused app doesn't lose the image it is
/// currently displaying.
final class GenerationStore {

    private let directory: URL
    private let retain: Int
    private let fm = FileManager.default
    private var counter: UInt64 = 0
    private let lock = NSLock()

    /// - Parameter retain: how many recent generations to keep on disk. Must be
    ///   at least 2: WallpaperAgent reads the file lazily and asynchronously, so
    ///   deleting the immediately-previous generation the instant a new one is
    ///   set can race and leave a blank desktop.
    init(directory: URL, retain: Int = 8) {
        self.directory = directory
        self.retain = max(2, retain)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static let prefix = "wp-"

    /// A fresh, unused path. Monotonic counter plus timestamp so that even a
    /// same-millisecond burst cannot collide, and so ordering on disk is
    /// recoverable from the name alone.
    func nextURL(ext: String = "png") -> URL {
        lock.lock()
        counter &+= 1
        let n = counter
        lock.unlock()

        let stamp = UInt64(Date().timeIntervalSince1970 * 1000)
        return directory.appendingPathComponent("\(Self.prefix)\(stamp)-\(n).\(ext)")
    }

    /// Deletes old generations, always preserving `keeping` (the live wallpaper)
    /// and the most recent `retain` files.
    func collect(keeping live: URL?) {
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let generated = entries
            .filter { $0.lastPathComponent.hasPrefix(Self.prefix) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }

        guard generated.count > retain else { return }

        let liveResolved = live?.resolvingSymlinksInPath().standardizedFileURL
        for stale in generated.dropFirst(retain) {
            if stale.resolvingSymlinksInPath().standardizedFileURL == liveResolved { continue }
            try? fm.removeItem(at: stale)
        }
    }
}
