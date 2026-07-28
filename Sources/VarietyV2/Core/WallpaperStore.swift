import Foundation

/// Reads the wallpaper that macOS actually has on screen.
///
/// `NSWorkspace.desktopImageURL(for:)` cannot be used for this on macOS 26 —
/// measured, it returns `/System/Library/CoreServices/DefaultDesktop.heic` no
/// matter what is displayed. The authoritative state lives in WallpaperAgent's
/// index, which is a plist containing *nested* binary plists:
///
/// ```
/// Index.plist
///   Displays / <display-uuid> / Desktop / Content / Choices[0]
///     Provider      "com.apple.wallpaper.choice.image"
///     Configuration <Data> -> { type: "imageFile", url: { relative: "file:///..." } }
/// ```
///
/// `AllSpacesAndDisplays` holds the same shape and is the fallback when no
/// per-display override has been written yet.
enum WallpaperStore {

    static let indexURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    /// The image file currently set, or nil when the desktop is on a dynamic
    /// system wallpaper (e.g. `com.apple.wallpaper.choice.sequoia`), which has
    /// no backing file we can point at.
    ///
    /// WallpaperAgent flushes this index asynchronously — measured at a second
    /// or two behind `setDesktopImageURL`. Reading straight after a set will
    /// often still show the previous value, so this is for reporting current
    /// state, not for confirming a set succeeded.
    static func currentImageURL() -> URL? {
        guard
            let data = try? Data(contentsOf: indexURL),
            let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        if let displays = root["Displays"] as? [String: Any] {
            for (_, value) in displays {
                if let url = imageURL(inContainer: value) { return url }
            }
        }
        return imageURL(inContainer: root["AllSpacesAndDisplays"])
    }

    /// True when the desktop is showing something this app generated.
    static func isShowingGeneratedImage(in directory: URL) -> Bool {
        guard let current = currentImageURL() else { return false }
        return current.resolvingSymlinksInPath().path
            .hasPrefix(directory.resolvingSymlinksInPath().path)
    }

    // MARK: - Plist spelunking

    /// A container is one of the `Displays/<uuid>` or `AllSpacesAndDisplays`
    /// dictionaries. Its interesting child is keyed by state — `Desktop` when a
    /// still image is set, `Linked`/`Idle` for the system dynamic wallpapers.
    private static func imageURL(inContainer container: Any?) -> URL? {
        guard let dict = container as? [String: Any] else { return nil }

        for key in ["Desktop", "Linked", "Idle"] {
            guard
                let slot = dict[key] as? [String: Any],
                let content = slot["Content"] as? [String: Any],
                let choices = content["Choices"] as? [[String: Any]]
            else { continue }

            for choice in choices {
                guard choice["Provider"] as? String == "com.apple.wallpaper.choice.image",
                      let config = choice["Configuration"] as? Data,
                      let url = decodeImageFileConfiguration(config)
                else { continue }
                return url
            }
        }
        return nil
    }

    /// The `Configuration` blob is itself a binary plist:
    /// `{ type: "imageFile", url: { relative: "file:///…" } }`
    private static func decodeImageFileConfiguration(_ data: Data) -> URL? {
        guard
            !data.isEmpty,
            let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let urlDict = inner["url"] as? [String: Any],
            let relative = urlDict["relative"] as? String
        else { return nil }
        return URL(string: relative)
    }
}
