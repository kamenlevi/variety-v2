import Foundation

/// Bing's Photo of the Day archive. No credentials; returns roughly the last
/// 100 days depending on market.
struct BingSource: ImageSource {
    let id = "bing"
    let displayName = "Bing Photo of the Day"

    /// `n` caps out well below 100 in practice; Bing silently returns fewer.
    private static let endpoint = URL(string:
        "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=100&mkt=en-US")!

    private struct Response: Decodable {
        struct Item: Decodable {
            let startdate: String
            let urlbase: String
            let copyright: String
            let copyrightlink: String?
            /// 0 when Bing considers the image unsuitable as a wallpaper
            /// (usually video stills). Decoded leniently: the field has
            /// appeared as both bool and int over the years.
            let wp: Bool?
        }
        let images: [Item]
    }

    func fetch() async throws -> [RemoteImage] {
        let response = try await Net.json(Response.self, from: Self.endpoint)

        return response.images.compactMap { item in
            guard item.wp != false else { return nil }

            // urlbase looks like "/th?id=OHR.ChannelKelp_EN-US3809417919".
            // Appending _UHD.jpg yields the highest resolution Bing publishes.
            guard let url = URL(string: "https://www.bing.com\(item.urlbase)_UHD.jpg") else { return nil }

            // The OHR token is stable per image and makes a better identity
            // than the date, which repeats across markets.
            let token = item.urlbase
                .components(separatedBy: "id=OHR.").last?
                .components(separatedBy: "_").first ?? item.startdate

            return RemoteImage(
                id: "bing:\(token)",
                imageURL: url,
                originURL: item.copyrightlink.flatMap(URL.init(string:)),
                title: item.copyright,
                author: nil,
                sourceName: displayName
            )
        }
    }
}
