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
    /// Pages of 30 to request when searching.
    var pages: Int = 1

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

        // Two different endpoints, and picking the wrong one caps the results
        // hard. `/photos/random` returns at most 30 photos and has no notion of
        // paging, so a search could never yield more than that however many
        // matches Unsplash actually holds. `/search/photos` is the searchable,
        // pageable one — tens of thousands of results for a common term.
        guard !query.isEmpty else { return try await fetchRandom(accessKey: accessKey) }

        let results: [[RemoteImage]] = await withTaskGroup(of: [RemoteImage].self) { group in
            for page in 1...max(1, pages) {
                group.addTask {
                    (try? await search(accessKey: accessKey, page: page)) ?? []
                }
            }
            var all: [[RemoteImage]] = []
            for await batch in group { all.append(batch) }
            return all
        }

        var seen = Set<String>()
        return results.flatMap { $0 }.filter { seen.insert($0.id).inserted }
    }

    private struct SearchResponse: Decodable {
        let results: [Photo]
        let total: Int?
    }

    private func search(accessKey: String, page: Int) async throws -> [RemoteImage] {
        var components = URLComponents(string: "https://api.unsplash.com/search/photos")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: "30"),      // Unsplash's maximum
            URLQueryItem(name: "page", value: "\(page)"),
            // Wallpapers are landscape; asking Unsplash saves filtering later.
            URLQueryItem(name: "orientation", value: "landscape"),
            URLQueryItem(name: "client_id", value: accessKey),
        ]

        do {
            let response = try await Net.json(SearchResponse.self, from: components.url!)
            return convert(response.results)
        } catch SourceError.badResponse(401) {
            throw SourceError.needsCredentials(displayName)
        }
    }

    private func fetchRandom(accessKey: String) async throws -> [RemoteImage] {
        var components = URLComponents(string: "https://api.unsplash.com/photos/random")!
        components.queryItems = [
            URLQueryItem(name: "count", value: "\(count)"),
            URLQueryItem(name: "orientation", value: "landscape"),
            URLQueryItem(name: "client_id", value: accessKey),
        ]

        do {
            let photos = try await Net.json([Photo].self, from: components.url!)

            return convert(photos)
        } catch SourceError.badResponse(401) {
            throw SourceError.needsCredentials(displayName)
        }
    }

    /// Unsplash resizes on delivery, so ask for the width this screen actually
    /// needs instead of pulling a 6000px original and throwing most of it away.
    /// Variety does the same with max(1980, width * 1.2).
    private func convert(_ photos: [Photo]) -> [RemoteImage] {
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
    }
}
