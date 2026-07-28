import Foundation

/// RSS/Atom image extraction, shared by ArtStation and any user-supplied Media
/// RSS feed.
///
/// Variety takes the same route for ArtStation rather than using the site API —
/// which turns out to be the only workable one, since ArtStation's project JSON
/// now sits behind a Cloudflare challenge while the RSS feeds stay open.
///
/// Images are collected from, in order of preference:
///   - `media:content` / `media:thumbnail` url attributes (true Media RSS)
///   - `<img src>` inside `content:encoded` or `<description>` (what
///     ArtStation actually emits)
struct FeedSource: ImageSource {
    let id: String
    let displayName: String
    let feedURL: URL
    /// Cap per item — ArtStation posts often carry a dozen assets and one
    /// project shouldn't flood the queue.
    var maxImagesPerItem = 3

    func fetch() async throws -> [RemoteImage] {
        let data = try await Net.data(feedURL)
        let items = FeedParser.parse(data)

        var out: [RemoteImage] = []
        for item in items {
            let urls = item.imageURLs.prefix(maxImagesPerItem)
            for (index, url) in urls.enumerated() {
                // Feeds rarely carry a stable per-image id, so identity is the
                // item link plus position — stable across refetches of the
                // same feed.
                let identity = "\(id):\(item.link ?? url.absoluteString)#\(index)"
                out.append(RemoteImage(
                    id: identity,
                    imageURL: url,
                    originURL: item.link.flatMap(URL.init(string:)),
                    title: item.title,
                    author: item.author,
                    sourceName: displayName
                ))
            }
        }
        return out
    }
}

/// ArtStation Trending, which is just a well-known feed.
extension FeedSource {
    static func artStationTrending() -> FeedSource {
        FeedSource(
            id: "artstation",
            displayName: "ArtStation Trending",
            feedURL: URL(string: "https://www.artstation.com/artwork.rss")!
        )
    }

    /// A specific artist's feed, e.g. username "soohyuenkwon7".
    static func artStationUser(_ username: String) -> FeedSource {
        FeedSource(
            id: "artstation:\(username)",
            displayName: "ArtStation — \(username)",
            feedURL: URL(string: "https://www.artstation.com/\(username).rss")!
        )
    }
}

// MARK: - Parsing

struct FeedItem {
    var title: String?
    var link: String?
    var author: String?
    var imageURLs: [URL] = []
}

/// Minimal event-driven RSS/Atom reader built on `XMLParser`, so there is no
/// third-party XML dependency.
private final class FeedParser: NSObject, XMLParserDelegate {

    static func parse(_ data: Data) -> [FeedItem] {
        let parser = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false  // keep "media:content" as one name
        xml.parse()
        return parser.items
    }

    private var items: [FeedItem] = []
    private var current: FeedItem?
    private var text = ""
    /// Collected across description/content:encoded, deduped at item close.
    private var htmlBlobs: [String] = []

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attrs: [String: String] = [:]) {
        text = ""

        switch element {
        case "item", "entry":
            current = FeedItem()
            htmlBlobs = []

        case "media:content", "media:thumbnail", "enclosure":
            if let raw = attrs["url"], let url = URL(string: raw), isImage(raw) {
                current?.imageURLs.append(url)
            }

        case "link":
            // Atom puts the link in an href attribute; RSS uses element text.
            if let href = attrs["href"], current?.link == nil {
                current?.link = href
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch element {
        case "title":
            if current?.title == nil { current?.title = value }
        case "link", "guid":
            if current?.link == nil || element == "link", !value.isEmpty, value.hasPrefix("http") {
                current?.link = value
            }
        case "dc:creator", "author", "name":
            if current?.author == nil, !value.isEmpty { current?.author = value }
        case "description", "content:encoded", "content", "summary":
            htmlBlobs.append(value)

        case "item", "entry":
            if var item = current {
                if item.imageURLs.isEmpty {
                    item.imageURLs = Self.imageSources(inHTML: htmlBlobs.joined(separator: "\n"))
                }
                // Preserve order while removing repeats — feeds commonly wrap
                // each <img> in an <a href> to the same file.
                var seen = Set<String>()
                item.imageURLs = item.imageURLs.filter { seen.insert($0.absoluteString).inserted }
                if !item.imageURLs.isEmpty { items.append(item) }
            }
            current = nil
            htmlBlobs = []

        default:
            break
        }
        text = ""
    }

    private func isImage(_ url: String) -> Bool {
        let lower = url.lowercased()
        return [".jpg", ".jpeg", ".png", ".webp", ".heic"].contains { lower.contains($0) }
    }

    /// Pulls `src` out of `<img>` tags. A regex is adequate here: the input is
    /// machine-generated feed markup, not arbitrary web HTML.
    private static func imageSources(inHTML html: String) -> [URL] {
        let pattern = #"<img[^>]+src\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: html) else { return nil }
            var raw = String(html[r])
            if raw.hasPrefix("//") { raw = "https:" + raw }
            return URL(string: raw)
        }
    }
}
