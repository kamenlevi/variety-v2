import Foundation

/// A subreddit's image posts, e.g. r/EarthPorn or r/wallpapers.
///
/// Reddit closed off anonymous JSON access after the 2023 API changes; the
/// public `.json` endpoints now answer 403/503 to unauthenticated clients
/// regardless of User-Agent (verified against r/EarthPorn while building this).
/// A free script-type app at https://www.reddit.com/prefs/apps supplies the
/// client id and secret, which are exchanged here for an OAuth token.
///
/// Without credentials this source reports `needsCredentials` rather than
/// failing obscurely — the anonymous path is left in place because self-hosted
/// and mirror instances still honour it.
struct RedditSource: ImageSource {
    let id: String
    let displayName: String
    var needsCredentials: Bool { true }

    var subreddit: String
    /// hot / new / top / rising
    var listing: String = "top"
    /// hour / day / week / month / year / all — only meaningful for `top`.
    var timeRange: String = "week"
    var limit: Int = 50

    var clientID: String?
    var clientSecret: String?

    init(subreddit: String, listing: String = "top", timeRange: String = "week",
         clientID: String? = nil, clientSecret: String? = nil) {
        self.subreddit = subreddit
        self.listing = listing
        self.timeRange = timeRange
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.id = "reddit:\(subreddit)"
        self.displayName = "r/\(subreddit)"
    }

    private struct Listing: Decodable {
        struct Wrapper: Decodable { let data: Post }
        struct Post: Decodable {
            let id: String
            let title: String?
            let url: String?
            let permalink: String?
            let over_18: Bool?
            let author: String?
            let post_hint: String?
        }
        struct Data: Decodable { let children: [Wrapper] }
        let data: Data
    }

    private struct Token: Decodable { let access_token: String }

    func fetch() async throws -> [RemoteImage] {
        let path = "r/\(subreddit)/\(listing).json?limit=\(limit)&t=\(timeRange)"

        let listing: Listing
        if let token = try await accessToken() {
            // The OAuth host mirrors the public one but under oauth.reddit.com.
            let url = URL(string: "https://oauth.reddit.com/" + path)!
            listing = try await Net.json(Listing.self, from: url, ua: Net.redditUA,
                                         headers: ["Authorization": "Bearer \(token)"])
        } else {
            let url = URL(string: "https://www.reddit.com/" + path)!
            do {
                listing = try await Net.json(Listing.self, from: url, ua: Net.redditUA)
            } catch SourceError.badResponse(403), SourceError.badResponse(429), SourceError.badResponse(503) {
                throw SourceError.needsCredentials(displayName)
            }
        }

        return listing.data.children.compactMap { child -> RemoteImage? in
            let post = child.data
            guard let raw = post.url, let url = URL(string: raw), Self.looksLikeImage(raw) else { return nil }

            return RemoteImage(
                id: "reddit:\(post.id)",
                imageURL: url,
                originURL: post.permalink.flatMap { URL(string: "https://www.reddit.com" + $0) },
                title: post.title,
                author: post.author.map { "u/\($0)" },
                sourceName: displayName
            )
        }
    }

    /// Client-credentials grant. Returns nil when no app is configured, so the
    /// caller can fall back to the anonymous path.
    private func accessToken() async throws -> String? {
        guard let clientID, let clientSecret, !clientID.isEmpty, !clientSecret.isEmpty else { return nil }

        var request = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        request.httpMethod = "POST"
        request.httpBody = Data("grant_type=client_credentials".utf8)
        request.setValue(Net.redditUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.needsCredentials(displayName)
        }
        return try? JSONDecoder().decode(Token.self, from: data).access_token
    }

    /// Reddit posts link to galleries and articles as well as images; only
    /// direct image links are usable as wallpapers.
    private static func looksLikeImage(_ url: String) -> Bool {
        let lower = url.lowercased()
        return [".jpg", ".jpeg", ".png", ".webp"].contains { lower.hasSuffix($0) }
    }
}
