import Foundation

/// Wallhaven search. Works anonymously for SFW content; an API key is only
/// needed for NSFW purity levels and for a user's own collections.
struct WallhavenSource: ImageSource {
    let id = "wallhaven"
    let displayName = "Wallhaven"

    /// Free-text query, or empty for the general random feed.
    var query: String = ""
    /// General / Anime / People, in Wallhaven's positional-bitstring form.
    var categories: String = "100"
    /// SFW / Sketchy / NSFW. Sketchy and NSFW are ignored without a key.
    var purity: String = "100"
    var apiKey: String?
    var minimumWidth: Int = 1920

    /// Converts a plain phrase into Wallhaven's tag syntax.
    ///
    /// Wallhaven does not do free-text search. A bare multi-word query is
    /// matched as a *single exact tag*, so "real dark forest" returns zero
    /// results while "+real +dark +forest" returns thousands. Typing a phrase
    /// and getting nothing back is the most likely thing a user will do, so
    /// the phrase is translated rather than passed through.
    ///
    /// Anything already using Wallhaven's own operators (`+`, `-`, `@user`,
    /// `id:`, `like:`, or a quoted phrase) is left exactly as written.
    static func tagQuery(from raw: String) -> String {
        let query = raw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return query }

        let operators: [Character] = ["+", "-", "@", "\""]
        if let first = query.first, operators.contains(first) { return query }
        if query.contains(":") { return query }          // id:, like:, type:
        if query.contains(" +") || query.contains(" -") { return query }

        let words = query.split(separator: " ").filter { !$0.isEmpty }
        guard words.count > 1 else { return query }

        return words.map { "+\($0)" }.joined(separator: " ")
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let id: String
            let url: String
            let path: String
            let dimension_x: Int
            let dimension_y: Int
        }
        let data: [Item]
    }

    func fetch() async throws -> [RemoteImage] {
        // Wallhaven ANDs tags, and a descriptive phrase usually names no single
        // wallpaper: "+real +dark +forest" matches nothing, while "+dark
        // +forest" matches ~2,800 and "+forest" ~2,900. Rather than hand back
        // nothing, drop the leading words one at a time — adjectives tend to
        // come first and the subject last, so this converges on what was meant.
        for attempt in Self.relaxations(of: query) {
            let images = try await fetch(tagQuery: attempt)
            if !images.isEmpty { return images }
        }
        return []
    }

    /// The query, then progressively broader versions of it.
    static func relaxations(of raw: String) -> [String] {
        let full = tagQuery(from: raw)
        guard full.hasPrefix("+") else { return [full] }

        var terms = full.split(separator: " ").map(String.init)
        var ladder = [full]
        while terms.count > 1 {
            terms.removeFirst()
            ladder.append(terms.joined(separator: " "))
        }
        return ladder
    }

    private func fetch(tagQuery: String) async throws -> [RemoteImage] {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/search")!

        // `atleast` is computed from the actual display rather than hardcoded,
        // so Wallhaven only returns wallpapers that can fill this screen. This
        // is Variety's approach: constrain at the API, not after downloading.
        let screen = ScreenGeometry.primaryPixelSize
        var items = [
            URLQueryItem(name: "categories", value: categories),
            URLQueryItem(name: "purity", value: purity),
            URLQueryItem(name: "atleast", value: "\(Int(screen.width))x\(Int(screen.height))"),
        ]

        if tagQuery.isEmpty {
            items.append(URLQueryItem(name: "sorting", value: "random"))
        } else {
            // With a search term, Variety sorts by favourites descending — the
            // best of the matches rather than an arbitrary slice of them.
            items.append(URLQueryItem(name: "q", value: tagQuery))
            items.append(URLQueryItem(name: "sorting", value: "favorites"))
            items.append(URLQueryItem(name: "order", value: "desc"))
            // Honoured only for authenticated requests, but harmless otherwise.
            items.append(URLQueryItem(name: "ai_art_filter", value: "1"))
        }

        if let apiKey, !apiKey.isEmpty { items.append(URLQueryItem(name: "apikey", value: apiKey)) }
        components.queryItems = items

        // A key that is present but wrong comes back as 401; surface that as a
        // credentials problem rather than a generic HTTP failure.
        do {
            let response = try await Net.json(Response.self, from: components.url!)
            return response.data.compactMap { item -> RemoteImage? in
                guard let imageURL = URL(string: item.path) else { return nil }
                return RemoteImage(
                    id: "wallhaven:\(item.id)",
                    imageURL: imageURL,
                    originURL: URL(string: item.url),
                    title: nil,
                    author: nil,
                    sourceName: displayName,
                    pixelWidth: item.dimension_x,
                    pixelHeight: item.dimension_y
                )
            }
        } catch SourceError.badResponse(401) {
            throw SourceError.needsCredentials(displayName)
        }
    }
}
