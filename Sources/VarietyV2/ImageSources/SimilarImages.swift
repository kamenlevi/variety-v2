import Foundation

/// Works out what "more like this one" means for a given wallpaper.
///
/// Nothing in Variety does this. It exists because choosing good wallpapers by
/// typing search terms is guesswork — you find one you like and have no way to
/// say "more of that". The image itself knows: Wallhaven and Unsplash both tag
/// their photos, so the tags of something you liked make a far better query
/// than anything you would have thought to type.
enum SimilarImages {

    struct Suggestion {
        /// The source kind to search.
        let kind: Source.Kind
        /// The query, already in that service's syntax.
        let query: String
        /// The individual terms, for showing what it decided and why.
        let terms: [String]
    }

    /// Tags too generic to narrow anything down. "nature" matches half of
    /// Wallhaven; keeping it would make every suggestion identical.
    private static let tooBroad: Set<String> = [
        "nature", "photography", "wallpaper", "wallpapers", "background",
        "hd", "4k", "art", "digital art", "cgi", "image", "photo", "picture",
        "bright", "dark", "colorful", "beautiful", "landscape",
    ]

    static func suggestion(for image: RemoteImage) async -> Suggestion? {
        let identifier = image.id.split(separator: ":").dropFirst().joined(separator: ":")

        if image.id.hasPrefix("wallhaven:") {
            if let tags = await wallhavenTags(id: identifier), !tags.isEmpty {
                let chosen = rank(tags)
                guard !chosen.isEmpty else { return nil }
                return Suggestion(
                    kind: .wallhaven,
                    query: chosen.map { "+\($0.replacingOccurrences(of: " ", with: "_"))" }
                        .joined(separator: " "),
                    terms: chosen)
            }
        }

        if image.id.hasPrefix("unsplash:") {
            if let tags = await unsplashTags(id: identifier), !tags.isEmpty {
                let chosen = rank(tags)
                guard !chosen.isEmpty else { return nil }
                return Suggestion(kind: .unsplash,
                                  query: chosen.joined(separator: " "),
                                  terms: chosen)
            }
        }

        // Anything else — Bing, APOD, a feed — has no tags, but its title is
        // descriptive prose. Falling back to that is better than refusing.
        if let title = image.title {
            let words = rank(keywords(from: title))
            if !words.isEmpty {
                return Suggestion(kind: .wallhaven,
                                  query: words.map { "+\($0)" }.joined(separator: " "),
                                  terms: words)
            }
        }
        return nil
    }

    /// Keeps the most specific two or three tags.
    ///
    /// Tag lists are ordered roughly most- to least-specific, and combining
    /// more than three with AND reliably returns nothing — the same failure as
    /// a typed phrase.
    private static func rank(_ tags: [String]) -> [String] {
        let usable = tags
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !tooBroad.contains($0) && $0.count > 2 }

        var seen = Set<String>()
        return Array(usable.filter { seen.insert($0).inserted }.prefix(3))
    }

    /// Content words from a title, with the usual filler removed.
    private static func keywords(from title: String) -> [String] {
        let stop: Set<String> = [
            "the", "and", "for", "with", "from", "near", "over", "into", "onto",
            "this", "that", "its", "his", "her", "their", "was", "are", "were",
            "national", "park", "photo", "day", "image", "view",
        ]
        return title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stop.contains($0) }
    }

    // MARK: - Tag lookups

    private struct WallhavenDetail: Decodable {
        struct Tag: Decodable { let name: String }
        struct Payload: Decodable { let tags: [Tag]? }
        let data: Payload
    }

    private static func wallhavenTags(id: String) async -> [String]? {
        guard let url = URL(string: "https://wallhaven.cc/api/v1/w/\(id)"),
              let detail = try? await Net.json(WallhavenDetail.self, from: url)
        else { return nil }
        return detail.data.tags?.map(\.name)
    }

    private struct UnsplashDetail: Decodable {
        struct Tag: Decodable { let title: String? }
        let tags: [Tag]?
    }

    private static func unsplashTags(id: String) async -> [String]? {
        let key = Settings.load().unsplashAccessKey
        guard !key.isEmpty,
              let url = URL(string: "https://api.unsplash.com/photos/\(id)?client_id=\(key)"),
              let detail = try? await Net.json(UnsplashDetail.self, from: url)
        else { return nil }
        return detail.tags?.compactMap(\.title)
    }
}
