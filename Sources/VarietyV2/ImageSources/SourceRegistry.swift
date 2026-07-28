import Foundation

/// The sources available to the app, and which of them are usable right now.
enum SourceRegistry {

    /// Sources that work with no setup at all. These are what a fresh install
    /// rotates through.
    static func defaults() -> [any ImageSource] {
        [
            BingSource(),
            EarthviewSource(),
            APODSource(),
            WallhavenSource(),
            FeedSource.artStationTrending(),
        ]
    }

    /// Everything, including sources that will refuse to run until the user
    /// supplies credentials in Settings.
    static func all(settings: Settings) -> [any ImageSource] {
        var sources = defaults()

        var wallhaven = WallhavenSource()
        wallhaven.apiKey = settings.wallhavenAPIKey
        if let index = sources.firstIndex(where: { $0.id == "wallhaven" }) {
            sources[index] = wallhaven
        }

        if let key = settings.unsplashAccessKey, !key.isEmpty {
            var unsplash = UnsplashSource()
            unsplash.accessKey = key
            sources.append(unsplash)
        }

        for subreddit in settings.subreddits {
            sources.append(RedditSource(
                subreddit: subreddit,
                clientID: settings.redditClientID,
                clientSecret: settings.redditClientSecret
            ))
        }

        for feed in settings.customFeeds {
            guard let url = URL(string: feed) else { continue }
            sources.append(FeedSource(id: "feed:\(feed)", displayName: url.host ?? feed, feedURL: url))
        }

        return sources
    }

    static func source(withID id: String, settings: Settings) -> (any ImageSource)? {
        all(settings: settings).first { $0.id == id }
    }
}
