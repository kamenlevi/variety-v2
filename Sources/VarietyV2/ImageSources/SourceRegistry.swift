import Foundation

/// Turns the user's Images table into things that can actually produce files.
///
/// Variety makes no distinction between a local folder and a web downloader —
/// both are rows in one list — so neither does this. Local sources yield files
/// directly; remote ones yield `RemoteImage` candidates to download.
enum SourceRegistry {

    /// A remote source built from a table row, or nil for local kinds.
    ///
    /// `breadth` asks for more results than the rotation needs — the search
    /// preview uses it, because judging a query by a single page of 24 (of
    /// which perhaps half survive the screen filter) is not judging it at all.
    static func downloader(for source: Source, settings: Settings,
                           breadth: Bool = false) -> (any ImageSource)? {
        guard source.kind.isDownloader else { return nil }
        // Honour Variety's global internet switch.
        guard settings.internetEnabled else { return nil }

        switch source.kind {
        case .bing:
            return BingSource()
        case .earthview:
            return EarthviewSource()
        case .apod:
            return APODSource()

        case .wallhaven:
            var wallhaven = WallhavenSource()
            wallhaven.query = source.location
            wallhaven.apiKey = settings.wallhavenAPIKey.isEmpty ? nil : settings.wallhavenAPIKey
            wallhaven.pages = breadth ? 5 : 1
            // Variety's safe mode forces SFW regardless of the key.
            if settings.safeMode { wallhaven.purity = "100" }
            return wallhaven

        case .artstation:
            return source.location.isEmpty
                ? FeedSource.artStationTrending()
                : FeedSource.artStationUser(source.location)

        case .unsplash:
            guard !settings.unsplashAccessKey.isEmpty else { return nil }
            var unsplash = UnsplashSource()
            unsplash.accessKey = settings.unsplashAccessKey
            unsplash.query = source.location
            // 30 is Unsplash's per-request maximum.
            unsplash.count = 30
            return unsplash

        case .reddit:
            return RedditSource(
                subreddit: source.location,
                clientID: settings.redditClientID.isEmpty ? nil : settings.redditClientID,
                clientSecret: settings.redditClientSecret.isEmpty ? nil : settings.redditClientSecret)

        case .mediarss:
            guard let url = URL(string: source.location) else { return nil }
            return FeedSource(id: "mediarss:\(source.location)",
                              displayName: url.host ?? source.location,
                              feedURL: url)

        case .image, .folder, .favorites, .fetched:
            return nil
        }
    }

    /// Local files contributed by a row — a folder's contents, the favourites
    /// folder, the fetched folder, or a single pinned image.
    static func localFiles(for source: Source, settings: Settings) -> [URL] {
        let directory: URL
        switch source.kind {
        case .favorites: directory = settings.favoritesFolderURL
        case .fetched:   directory = settings.fetchedFolderURL
        case .folder:    directory = settings.expand(source.location)
        case .image:
            let file = settings.expand(source.location)
            return FileManager.default.fileExists(atPath: file.path) ? [file] : []
        default:
            return []
        }
        return imageFiles(in: directory)
    }

    /// Recursive, because Variety's folder sources include subfolders.
    static func imageFiles(in directory: URL) -> [URL] {
        let extensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "bmp", "gif"]
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in walker {
            if extensions.contains(url.pathExtension.lowercased()) { found.append(url) }
            // A wallpaper folder can be enormous; this is a pool to draw from,
            // not an index, so an upper bound keeps refill snappy.
            if found.count >= 5000 { break }
        }
        return found
    }

    /// Every enabled remote source, ready to fetch.
    static func activeDownloaders(settings: Settings) -> [any ImageSource] {
        settings.sources
            .filter(\.enabled)
            .compactMap { downloader(for: $0, settings: settings) }
    }

    /// Every enabled local file.
    static func activeLocalFiles(settings: Settings) -> [URL] {
        settings.sources
            .filter(\.enabled)
            .flatMap { localFiles(for: $0, settings: settings) }
    }

    /// All source kinds a user can add from the Preferences table, with the
    /// label shown in the picker.
    static let addableKinds: [(Source.Kind, String)] = [
        (.folder, "Folder of images"),
        (.image, "A single image"),
        (.bing, "Bing Photo of the Day"),
        (.apod, "NASA's Astronomy Picture of the Day"),
        (.earthview, "Google Earth View"),
        (.wallhaven, "Wallhaven search"),
        (.unsplash, "Unsplash"),
        (.artstation, "ArtStation"),
        (.reddit, "Subreddit"),
        (.mediarss, "Media RSS feed"),
    ]
}
