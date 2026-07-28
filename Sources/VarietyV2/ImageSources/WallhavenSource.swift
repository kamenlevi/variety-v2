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

        if query.isEmpty {
            items.append(URLQueryItem(name: "sorting", value: "random"))
        } else {
            // With a search term, Variety sorts by favourites descending — the
            // best of the matches rather than an arbitrary slice of them.
            items.append(URLQueryItem(name: "q", value: query))
            items.append(URLQueryItem(name: "sorting", value: "favorites"))
            items.append(URLQueryItem(name: "order", value: "desc"))
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
