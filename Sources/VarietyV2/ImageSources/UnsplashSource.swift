import Foundation

/// Unsplash random photos.
///
/// Requires an access key, which the user registers themselves at
/// https://unsplash.com/developers. Variety ships its own key XOR-obfuscated in
/// the source; that key is not reused here — it is Variety's to spend against
/// their rate limit, and Unsplash's terms expect each application to register.
struct UnsplashSource: ImageSource {
    let id = "unsplash"
    let displayName = "Unsplash"
    var needsCredentials: Bool { true }

    var accessKey: String?
    /// Optional search terms; empty means the general random feed.
    var query: String = ""
    var count: Int = 30

    private struct Photo: Decodable {
        struct URLs: Decodable { let raw: String; let full: String }
        struct User: Decodable { let name: String?; let links: Links?
                                 struct Links: Decodable { let html: String? } }
        struct Links: Decodable { let html: String? }
        let id: String
        let description: String?
        let alt_description: String?
        let urls: URLs
        let user: User?
        let links: Links?
        let width: Int?
        let height: Int?
    }

    func fetch() async throws -> [RemoteImage] {
        guard let accessKey, !accessKey.isEmpty else {
            throw SourceError.needsCredentials(displayName)
        }

        var components = URLComponents(string: "https://api.unsplash.com/photos/random")!
        var items = [
            URLQueryItem(name: "count", value: "\(count)"),
            URLQueryItem(name: "client_id", value: accessKey),
        ]
        if !query.isEmpty { items.append(URLQueryItem(name: "query", value: query)) }
        components.queryItems = items

        do {
            let photos = try await Net.json([Photo].self, from: components.url!)

            // Unsplash resizes on delivery, so ask for the width this screen
            // actually needs instead of pulling a 6000px original and throwing
            // most of it away. Variety does the same with max(1980, width*1.2).
            let wanted = ScreenGeometry.requestWidth

            return photos.compactMap { photo -> RemoteImage? in
                let base = photo.urls.raw.isEmpty ? photo.urls.full : photo.urls.raw
                // Unsplash raw URLs already carry a query string.
                let separator = base.contains("?") ? "&" : "?"
                guard let imageURL = URL(string: "\(base)\(separator)w=\(wanted)&q=85") else { return nil }

                // Watermarked Unsplash+ images are excluded, as in Variety.
                guard !base.contains("plus.unsplash.com/") else { return nil }

                return RemoteImage(
                    id: "unsplash:\(photo.id)",
                    imageURL: imageURL,
                    originURL: photo.links?.html.flatMap(URL.init(string:)),
                    title: photo.description ?? photo.alt_description,
                    author: photo.user?.name,
                    sourceName: displayName,
                    pixelWidth: photo.width,
                    pixelHeight: photo.height
                )
            }
        } catch SourceError.badResponse(401) {
            throw SourceError.needsCredentials(displayName)
        }
    }
}
