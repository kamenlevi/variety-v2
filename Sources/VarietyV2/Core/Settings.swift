import Foundation

/// Variety's full option surface.
///
/// Field names deliberately mirror the originals in `variety/Options.py` — this
/// is meant to be legible to someone who knows the Python codebase, and to make
/// a config migration straightforward if one is ever wanted.
///
/// Options that existed purely to paper over Linux desktop-environment
/// differences are the only ones dropped: `set_wallpaper_script`,
/// `get_wallpaper_script`, `set_lock_screen_script`. macOS has exactly one way
/// to set a wallpaper, so there is nothing for a script hook to abstract.
struct Settings: Codable {

    // MARK: General

    var changeEnabled = true
    var changeOnStart = false
    /// Seconds. Variety's default is 300.
    var changeInterval: TimeInterval = 300
    var internetEnabled = true
    var safeMode = false
    var changeLockScreen = false
    var startAtLogin = false
    var changeOnWake = true

    // MARK: Downloading

    var downloadFolder = "~/Pictures/VarietyV2/Downloaded"
    /// Bias towards downloading new images vs reusing the pool, 0...1.
    var downloadPreferenceRatio = 0.9
    var quotaEnabled = true
    /// Megabytes.
    var quotaSize = 1000
    var wallhavenAPIKey = ""
    var unsplashAccessKey = ""
    var redditClientID = ""
    var redditClientSecret = ""

    // MARK: Favorites

    var favoritesFolder = "~/Pictures/VarietyV2/Favorites"
    /// What happens to an image when favourited, per origin.
    /// Variety's default: Downloaded→Copy, Fetched→Move, Others→Copy.
    var favoritesOperations: [FavoriteOperation] = [
        .init(origin: "Downloaded", operation: .copy),
        .init(origin: "Fetched", operation: .move),
        .init(origin: "Others", operation: .copy),
    ]

    // MARK: Wallpaper

    var wallpaperAutoRotate = true
    /// Variety defaults to "os" and lets the desktop environment decide. macOS
    /// scales crudely, so the default here is "smart": zoom when the image's
    /// shape is close to the screen's, blurred fill when cropping would lose
    /// too much.
    var wallpaperDisplayMode = "smart"

    // MARK: Fetched / clipboard

    var fetchedFolder = "~/Pictures/VarietyV2/Fetched"
    var clipboardEnabled = false
    var clipboardUseWhitelist = true
    var clipboardHosts = [
        "wallhaven.cc", "wallpapers.net", "imgur.com",
        "deviantart.com", "interfacelift.com", "vladstudio.com",
    ]

    // MARK: Appearance

    var icon = "Light"

    // MARK: Filtering

    var desiredColorEnabled = false
    /// RGB 0...255.
    var desiredColor: [Int]? = nil
    /// On by default, unlike Variety. Combined with the API-level size
    /// requests this is what makes "only images that fit my screen" true out
    /// of the box rather than something to go and switch on.
    var minSizeEnabled = true
    /// Percent of screen size.
    var minSize = 80
    var useLandscapeEnabled = true
    var lightnessEnabled = false
    var lightnessMode = LightnessMode.dark
    var minRatingEnabled = false
    var minRating = 4
    var nameRegexEnabled = false
    var nameRegex = ".*"

    // MARK: Quotes

    var quotesEnabled = false
    var quotesFont = "Serif 30"
    var quotesTextColor = [255, 255, 255]
    var quotesBgColor = [80, 80, 80]
    var quotesBgOpacity = 55
    var quotesTextShadow = false
    var quotesDisabledSources: [String] = []
    var quotesTags = ""
    var quotesAuthors = ""
    var quotesChangeEnabled = false
    var quotesChangeInterval: TimeInterval = 300
    /// Percentages, matching Variety's sliders.
    var quotesWidth = 70
    var quotesHpos = 100
    var quotesVpos = 40
    var quotesMaxLength = 250
    var quotesFavoritesFile = "~/Pictures/VarietyV2/favorite_quotes.txt"

    // MARK: Clock

    var clockEnabled = false
    var clockFont = "Serif 70"
    var clockDateFont = "Serif 30"
    /// Variety encodes clock layout in an ImageMagick argument string. There is
    /// no ImageMagick here, so the parts that actually vary are stored plainly.
    var clockTimeFormat = "HH:mm"
    var clockDateFormat = "EEEE, d MMMM"
    var clockHorizontalOffset = 60
    var clockVerticalOffset = 110

    // MARK: Slideshow

    var slideshowSourcesEnabled = true
    var slideshowFavoritesEnabled = true
    var slideshowDownloadsEnabled = false
    var slideshowCustomEnabled = false
    var slideshowCustomFolder = "~/Pictures"
    var slideshowSortOrder = "Random"
    var slideshowMonitor = "All"
    var slideshowMode = "Fullscreen"
    var slideshowSeconds = 6.0
    var slideshowFade = 0.4
    var slideshowZoom = 0.2
    var slideshowPan = 0.05

    // MARK: Sources and effects

    var sources: [Source] = Source.defaults
    var filters: [Filter] = Filter.defaults

    init() {}

    // MARK: - Paths

    func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    var downloadFolderURL: URL { expand(downloadFolder) }
    var favoritesFolderURL: URL { expand(favoritesFolder) }
    var fetchedFolderURL: URL { expand(fetchedFolder) }

    // MARK: - Persistence

    static let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/VarietyV2/settings.json")

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
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

    /// Decodes leniently — any absent key keeps its default.
    ///
    /// Swift's synthesized `Codable` throws `keyNotFound` for a missing key even
    /// when the property has a default value, so a settings file written by an
    /// older build would fail to decode entirely and silently reset every
    /// preference. With ninety-odd options and a project that expects to gain
    /// more, that failure mode is not survivable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        changeEnabled = v(.changeEnabled, d.changeEnabled)
        changeOnStart = v(.changeOnStart, d.changeOnStart)
        changeInterval = v(.changeInterval, d.changeInterval)
        internetEnabled = v(.internetEnabled, d.internetEnabled)
        safeMode = v(.safeMode, d.safeMode)
        changeLockScreen = v(.changeLockScreen, d.changeLockScreen)
        startAtLogin = v(.startAtLogin, d.startAtLogin)
        changeOnWake = v(.changeOnWake, d.changeOnWake)

        downloadFolder = v(.downloadFolder, d.downloadFolder)
        downloadPreferenceRatio = v(.downloadPreferenceRatio, d.downloadPreferenceRatio)
        quotaEnabled = v(.quotaEnabled, d.quotaEnabled)
        quotaSize = v(.quotaSize, d.quotaSize)
        wallhavenAPIKey = v(.wallhavenAPIKey, d.wallhavenAPIKey)
        unsplashAccessKey = v(.unsplashAccessKey, d.unsplashAccessKey)
        redditClientID = v(.redditClientID, d.redditClientID)
        redditClientSecret = v(.redditClientSecret, d.redditClientSecret)

        favoritesFolder = v(.favoritesFolder, d.favoritesFolder)
        favoritesOperations = v(.favoritesOperations, d.favoritesOperations)

        wallpaperAutoRotate = v(.wallpaperAutoRotate, d.wallpaperAutoRotate)
        wallpaperDisplayMode = v(.wallpaperDisplayMode, d.wallpaperDisplayMode)

        fetchedFolder = v(.fetchedFolder, d.fetchedFolder)
        clipboardEnabled = v(.clipboardEnabled, d.clipboardEnabled)
        clipboardUseWhitelist = v(.clipboardUseWhitelist, d.clipboardUseWhitelist)
        clipboardHosts = v(.clipboardHosts, d.clipboardHosts)

        icon = v(.icon, d.icon)

        desiredColorEnabled = v(.desiredColorEnabled, d.desiredColorEnabled)
        desiredColor = v(.desiredColor, d.desiredColor)
        minSizeEnabled = v(.minSizeEnabled, d.minSizeEnabled)
        minSize = v(.minSize, d.minSize)
        useLandscapeEnabled = v(.useLandscapeEnabled, d.useLandscapeEnabled)
        lightnessEnabled = v(.lightnessEnabled, d.lightnessEnabled)
        lightnessMode = v(.lightnessMode, d.lightnessMode)
        minRatingEnabled = v(.minRatingEnabled, d.minRatingEnabled)
        minRating = v(.minRating, d.minRating)
        nameRegexEnabled = v(.nameRegexEnabled, d.nameRegexEnabled)
        nameRegex = v(.nameRegex, d.nameRegex)

        quotesEnabled = v(.quotesEnabled, d.quotesEnabled)
        quotesFont = v(.quotesFont, d.quotesFont)
        quotesTextColor = v(.quotesTextColor, d.quotesTextColor)
        quotesBgColor = v(.quotesBgColor, d.quotesBgColor)
        quotesBgOpacity = v(.quotesBgOpacity, d.quotesBgOpacity)
        quotesTextShadow = v(.quotesTextShadow, d.quotesTextShadow)
        quotesDisabledSources = v(.quotesDisabledSources, d.quotesDisabledSources)
        quotesTags = v(.quotesTags, d.quotesTags)
        quotesAuthors = v(.quotesAuthors, d.quotesAuthors)
        quotesChangeEnabled = v(.quotesChangeEnabled, d.quotesChangeEnabled)
        quotesChangeInterval = v(.quotesChangeInterval, d.quotesChangeInterval)
        quotesWidth = v(.quotesWidth, d.quotesWidth)
        quotesHpos = v(.quotesHpos, d.quotesHpos)
        quotesVpos = v(.quotesVpos, d.quotesVpos)
        quotesMaxLength = v(.quotesMaxLength, d.quotesMaxLength)
        quotesFavoritesFile = v(.quotesFavoritesFile, d.quotesFavoritesFile)

        clockEnabled = v(.clockEnabled, d.clockEnabled)
        clockFont = v(.clockFont, d.clockFont)
        clockDateFont = v(.clockDateFont, d.clockDateFont)
        clockTimeFormat = v(.clockTimeFormat, d.clockTimeFormat)
        clockDateFormat = v(.clockDateFormat, d.clockDateFormat)
        clockHorizontalOffset = v(.clockHorizontalOffset, d.clockHorizontalOffset)
        clockVerticalOffset = v(.clockVerticalOffset, d.clockVerticalOffset)

        slideshowSourcesEnabled = v(.slideshowSourcesEnabled, d.slideshowSourcesEnabled)
        slideshowFavoritesEnabled = v(.slideshowFavoritesEnabled, d.slideshowFavoritesEnabled)
        slideshowDownloadsEnabled = v(.slideshowDownloadsEnabled, d.slideshowDownloadsEnabled)
        slideshowCustomEnabled = v(.slideshowCustomEnabled, d.slideshowCustomEnabled)
        slideshowCustomFolder = v(.slideshowCustomFolder, d.slideshowCustomFolder)
        slideshowSortOrder = v(.slideshowSortOrder, d.slideshowSortOrder)
        slideshowMonitor = v(.slideshowMonitor, d.slideshowMonitor)
        slideshowMode = v(.slideshowMode, d.slideshowMode)
        slideshowSeconds = v(.slideshowSeconds, d.slideshowSeconds)
        slideshowFade = v(.slideshowFade, d.slideshowFade)
        slideshowZoom = v(.slideshowZoom, d.slideshowZoom)
        slideshowPan = v(.slideshowPan, d.slideshowPan)

        sources = v(.sources, d.sources)
        filters = v(.filters, d.filters)
    }
}

// MARK: - Supporting types

enum LightnessMode: String, Codable, CaseIterable {
    case dark, light
    var displayName: String { self == .dark ? "Dark images" : "Light images" }
}

struct FavoriteOperation: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable { case copy = "Copy", move = "Move" }
    /// "Downloaded", "Fetched", "Others", or a folder path.
    var origin: String
    var operation: Kind
}

/// One entry in Variety's Images table: `[enabled, type, location]`.
///
/// Variety treats every image origin the same way — the favourites folder, the
/// fetched folder, an arbitrary local folder and a downloader all live in one
/// list. Keeping that shape is what makes the General tab's table work.
struct Source: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case image, folder, favorites, fetched
        case bing, unsplash, apod, earthview, wallhaven, artstation, reddit, mediarss

        var isDownloader: Bool {
            switch self {
            case .image, .folder, .favorites, .fetched: return false
            default: return true
            }
        }
        /// Whether the location field means anything the user can edit.
        var isEditable: Bool {
            switch self {
            case .wallhaven, .reddit, .mediarss, .unsplash, .folder: return true
            default: return false
            }
        }
        var isRemovable: Bool {
            switch self {
            case .favorites, .fetched: return false
            default: return true
            }
        }
    }

    var enabled: Bool
    var kind: Kind
    /// A folder path, a search query, a subreddit, or a feed URL depending on kind.
    var location: String

    var id: String { "\(kind.rawValue)|\(location)" }

    var displayLocation: String {
        switch kind {
        case .favorites: return "The Favorites folder"
        case .fetched: return "The Fetched folder"
        case .bing: return "Bing Photo of the Day"
        case .apod: return "NASA's Astronomy Picture of the Day"
        case .earthview: return "Google Earth View Wallpapers"
        case .artstation: return location.isEmpty ? "ArtStation Trending" : location
        case .unsplash: return location.isEmpty ? "High-resolution photos from Unsplash.com" : location
        default: return location
        }
    }

    /// Mirrors Variety's own starting set, adapted: it seeds a Linux system
    /// wallpaper folder that does not exist on macOS, so the equivalent Apple
    /// directory is used instead.
    static let defaults: [Source] = [
        .init(enabled: true, kind: .favorites, location: "The Favorites folder"),
        .init(enabled: true, kind: .fetched, location: "The Fetched folder"),
        .init(enabled: false, kind: .folder, location: "/System/Library/Desktop Pictures"),
        .init(enabled: true, kind: .bing, location: "Bing Photo of the Day"),
        .init(enabled: true, kind: .earthview, location: "Google Earth View Wallpapers"),
        .init(enabled: true, kind: .apod, location: "NASA's Astronomy Picture of the Day"),
        .init(enabled: true, kind: .wallhaven, location: "nature"),
        .init(enabled: true, kind: .artstation, location: ""),
        .init(enabled: false, kind: .unsplash, location: ""),
    ]
}

/// One entry in Variety's Effects list (the Customize tab).
///
/// Variety stores an ImageMagick argument string per effect. There is no
/// ImageMagick here, so the argument string is kept only as a recognisable
/// label and the rendering is chosen by name in `EffectRenderer`.
struct Filter: Codable, Equatable, Hashable, Identifiable {
    var enabled: Bool
    var name: String
    /// The original ImageMagick arguments, kept for reference and round-tripping.
    var arguments: String

    var id: String { name }

    static let defaults: [Filter] = [
        .init(enabled: false, name: "Keep original", arguments: ""),
        .init(enabled: false, name: "Grayscale", arguments: "-type Grayscale"),
        .init(enabled: false, name: "Heavy blur", arguments: "-blur 120x40"),
        .init(enabled: false, name: "Oil painting", arguments: "-paint 6"),
        .init(enabled: false, name: "Charcoal painting", arguments: "-charcoal 3"),
        .init(enabled: false, name: "Pointilism", arguments: "-spread 10 -noise 3"),
        .init(enabled: false, name: "Pixellate", arguments: "-scale 3% -scale 3333%"),
    ]
}

/// Variety's wallpaper display modes, from `variety/display_modes.py`.
enum DisplayMode: String, Codable, CaseIterable {
    case os
    case zoom
    case fillWithBlack = "fill-with-black"
    case fillWithBlur = "fill-with-blur"
    case smart

    var displayName: String {
        switch self {
        case .os: return "Set as-is, let the system scale it"
        case .zoom: return "Zoom to fill the screen"
        case .fillWithBlack: return "Fit within the screen, black background"
        case .fillWithBlur: return "Fit within the screen, blurred background"
        case .smart: return "Smart: zoom if close, otherwise blurred fill"
        }
    }

    var summary: String {
        switch self {
        case .os:
            return "The image is passed to macOS untouched at its own resolution."
        case .zoom:
            return "The image is scaled until it covers the screen; the overflow is cropped."
        case .fillWithBlack:
            return "The whole image stays visible, letterboxed with black."
        case .fillWithBlur:
            return "The whole image stays visible; the margins are filled with a blurred enlargement of it."
        case .smart:
            return "Zooms when the aspect ratio is close to the screen's, and falls back to a blurred fill when cropping would lose too much."
        }
    }
}
