import Foundation

/// Persisted preferences. Plain Codable JSON in Application Support rather than
/// UserDefaults, so the whole configuration is one inspectable, portable file —
/// closer to how Variety keeps its profile.
struct Settings: Codable {

    // Rotation
    var changeIntervalSeconds: TimeInterval = 600
    var changeOnWake: Bool = true
    var changeOnLogin: Bool = true
    var startAtLogin: Bool = false
    var paused: Bool = false

    // Sources
    var enabledSourceIDs: [String] = ["bing", "earthview", "apod", "wallhaven", "artstation"]
    var subreddits: [String] = []
    var customFeeds: [String] = []

    // Credentials — absent by default; the UI marks these sources as needing setup.
    var wallhavenAPIKey: String?
    var unsplashAccessKey: String?
    var redditClientID: String?
    var redditClientSecret: String?

    // Appearance
    var displayMode: DisplayMode = .zoom
    var quotesEnabled: Bool = false
    var clockEnabled: Bool = false

    // Library
    var downloadFolder: String = "~/Pictures/VarietyV2"
    var favoritesFolder: String = "~/Pictures/VarietyV2/Favorites"
    /// How many downloaded images to keep before pruning the oldest unfavourited ones.
    var keepDownloaded: Int = 200

    init() {}

    /// Decodes leniently: any key that is absent keeps its default.
    ///
    /// Swift's synthesized `Codable` throws `keyNotFound` for a missing key even
    /// when the property has a default value, so a settings file written by an
    /// older build — or one missing a field for any other reason — would fail
    /// to decode entirely and silently reset every preference. That is exactly
    /// how `startAtLogin` got reverted during development, taking the login
    /// item registration with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        let defaults = Settings()

        changeIntervalSeconds = value(.changeIntervalSeconds, defaults.changeIntervalSeconds)
        changeOnWake          = value(.changeOnWake, defaults.changeOnWake)
        changeOnLogin         = value(.changeOnLogin, defaults.changeOnLogin)
        startAtLogin          = value(.startAtLogin, defaults.startAtLogin)
        paused                = value(.paused, defaults.paused)

        enabledSourceIDs      = value(.enabledSourceIDs, defaults.enabledSourceIDs)
        subreddits            = value(.subreddits, defaults.subreddits)
        customFeeds           = value(.customFeeds, defaults.customFeeds)

        wallhavenAPIKey       = value(.wallhavenAPIKey, defaults.wallhavenAPIKey)
        unsplashAccessKey     = value(.unsplashAccessKey, defaults.unsplashAccessKey)
        redditClientID        = value(.redditClientID, defaults.redditClientID)
        redditClientSecret    = value(.redditClientSecret, defaults.redditClientSecret)

        displayMode           = value(.displayMode, defaults.displayMode)
        quotesEnabled         = value(.quotesEnabled, defaults.quotesEnabled)
        clockEnabled          = value(.clockEnabled, defaults.clockEnabled)

        downloadFolder        = value(.downloadFolder, defaults.downloadFolder)
        favoritesFolder       = value(.favoritesFolder, defaults.favoritesFolder)
        keepDownloaded        = value(.keepDownloaded, defaults.keepDownloaded)
    }

    // MARK: - Persistence

    static let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/VarietyV2/settings.json")

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            // Should not happen — decoding is lenient (see init(from:)) — but a
            // truly corrupt file must not silently reset every preference, so
            // say so rather than pretending the defaults were the user's choice.
            NSLog("VarietyV2: settings could not be read (\(error)); using defaults")
            return Settings()
        }
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }

    var expandedDownloadFolder: URL {
        URL(fileURLWithPath: (downloadFolder as NSString).expandingTildeInPath)
    }
    var expandedFavoritesFolder: URL {
        URL(fileURLWithPath: (favoritesFolder as NSString).expandingTildeInPath)
    }
}

/// How an image is fitted to the screen. Mirrors Variety's display modes; the
/// rendering is done in Core Image rather than by shelling out to ImageMagick.
enum DisplayMode: String, Codable, CaseIterable {
    case os              // hand the file to macOS untouched
    case zoom            // scale to fill, cropping overflow
    case fillWithBlack   // fit inside, letterbox with black
    case fillWithBlur    // fit inside, fill the margins with a blurred enlargement
    case oilPainting

    var displayName: String {
        switch self {
        case .os: return "System default"
        case .zoom: return "Zoom to fill"
        case .fillWithBlack: return "Fit, black bars"
        case .fillWithBlur: return "Fit, blurred background"
        case .oilPainting: return "Oil painting"
        }
    }
}
