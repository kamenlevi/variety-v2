import Foundation

/// Google Earth View satellite imagery (~2600 images).
///
/// Two-step: an index of slugs, then one detail request per slug for the actual
/// photo URL. The index is large (~290 KB) so it is fetched once and a random
/// sample of slugs is resolved, rather than resolving all 2600.
struct EarthviewSource: ImageSource {
    let id = "earthview"
    let displayName = "Google Earth View"

    private static let root = "https://new-images-preview-dot-earth-viewer.appspot.com/"
    private static let index = URL(string: root + "_api/photos.json")!

    /// How many slugs to resolve per fetch. Each is a separate request, so this
    /// trades freshness against politeness.
    private let sampleSize = 12

    private struct IndexEntry: Decodable { let slug: String }

    private struct Detail: Decodable {
        let id: String
        let slug: String
        let name: String?
        let country: String?
        let region: String?
        let attribution: String?
        let photoUrl: String
    }

    func fetch() async throws -> [RemoteImage] {
        let index = try await Net.json([IndexEntry].self, from: Self.index)
        let slugs = index.map(\.slug).shuffled().prefix(sampleSize)

        // Resolve concurrently but bounded by the sample size; a failed detail
        // fetch drops that one image rather than failing the whole source.
        return await withTaskGroup(of: RemoteImage?.self) { group in
            for slug in slugs {
                group.addTask { await resolve(slug: slug) }
            }
            var out: [RemoteImage] = []
            for await image in group { if let image { out.append(image) } }
            return out
        }
    }

    private func resolve(slug: String) async -> RemoteImage? {
        guard let url = URL(string: Self.root + "_api/" + slug + ".json"),
              let detail = try? await Net.json(Detail.self, from: url)
        else { return nil }

        // photoUrl is sometimes protocol-relative.
        var photo = detail.photoUrl
        if photo.hasPrefix("//") { photo = "https:" + photo }
        else if !photo.hasPrefix("http") { photo = "https://" + photo }
        guard let imageURL = URL(string: photo) else { return nil }

        let place = [detail.region, detail.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != "-" }
            .joined(separator: ", ")

        return RemoteImage(
            id: "earthview:\(detail.id)",
            imageURL: imageURL,
            originURL: URL(string: Self.root + detail.slug),
            title: detail.name ?? (place.isEmpty ? nil : place),
            author: detail.attribution,
            sourceName: displayName
        )
    }
}
