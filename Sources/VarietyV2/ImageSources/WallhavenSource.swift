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
        var items = [
            URLQueryItem(name: "categories", value: categories),
            URLQueryItem(name: "purity", value: purity),
            URLQueryItem(name: "sorting", value: "random"),
            URLQueryItem(name: "atleast", value: "\(minimumWidth)x1080"),
        ]
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let apiKey, !apiKey.isEmpty { items.append(URLQueryItem(name: "apikey", value: apiKey)) }
        components.queryItems = items

        // A key that is present but wrong comes back as 401; surface that as a
        // credentials problem rather than a generic HTTP failure.
        do {
            let response = try await Net.json(Response.self, from: components.url!)
            return response.data.map { item in
                RemoteImage(
                    id: "wallhaven:\(item.id)",
                    imageURL: URL(string: item.path)!,
                    originURL: URL(string: item.url),
                    title: nil,
                    author: nil,
                    sourceName: displayName
                )
            }
        } catch SourceError.badResponse(401) {
            throw SourceError.needsCredentials(displayName)
        }
    }
}
