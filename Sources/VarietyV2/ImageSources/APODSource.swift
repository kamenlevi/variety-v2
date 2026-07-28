import Foundation

/// NASA Astronomy Picture of the Day.
///
/// APOD has no JSON API of its own worth using here (the api.nasa.gov one is
/// key-gated), so this scrapes, exactly as Variety does: the archive page lists
/// every daily entry, and each entry page wraps its thumbnail in a link to the
/// full-resolution file.
struct APODSource: ImageSource {
    let id = "apod"
    let displayName = "NASA APOD"

    private static let root = "https://apod.nasa.gov/apod/"
    private static let archive = URL(string: root + "archivepix.html")!

    /// Entries to resolve per fetch. Each is a page load.
    private let sampleSize = 8

    func fetch() async throws -> [RemoteImage] {
        let html = String(decoding: try await Net.data(Self.archive), as: UTF8.self)

        // Archive entries are plain relative links of the form apYYMMDD.html.
        let pages = Self.matches(#"href="(ap\d{6}\.html)""#, in: html)
            .shuffled()
            .prefix(sampleSize)

        return await withTaskGroup(of: RemoteImage?.self) { group in
            for page in pages {
                group.addTask { await resolve(page: page) }
            }
            var out: [RemoteImage] = []
            for await image in group { if let image { out.append(image) } }
            return out
        }
    }

    private func resolve(page: String) async -> RemoteImage? {
        guard let pageURL = URL(string: Self.root + page),
              let data = try? await Net.data(pageURL)
        else { return nil }

        let html = String(decoding: data, as: UTF8.self)

        // Many APOD entries are videos (YouTube/Vimeo embeds) with no image at
        // all; those simply yield no match and are skipped.
        guard let href = Self.matches(#"<a href="(image/[^"]+\.(?:jpg|png))""#, in: html).first
                ?? Self.matches(#"<img src="(image/[^"]+\.(?:jpg|png))""#, in: html).first,
              let imageURL = URL(string: Self.root + href)
        else { return nil }

        let title = Self.matches(#"<b>\s*(.*?)\s*</b>"#, in: html).first?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        return RemoteImage(
            id: "apod:\(page)",
            imageURL: imageURL,
            originURL: pageURL,
            title: title,
            author: nil,
            sourceName: displayName
        )
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
