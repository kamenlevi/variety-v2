import Foundation

/// One candidate wallpaper, before download.
struct RemoteImage: Hashable, Codable {
    /// Stable identity used for de-duplication across fetches. Sources should
    /// derive this from the provider's own id where one exists, so the same
    /// picture seen twice is recognised even if the CDN URL changes.
    let id: String
    let imageURL: URL
    /// The human-facing page for this image — "view source" in the menu.
    let originURL: URL?
    let title: String?
    let author: String?
    let sourceName: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: RemoteImage, b: RemoteImage) -> Bool { a.id == b.id }
}

/// Why a source could not produce images. Distinguished so the UI can say
/// something useful rather than a generic failure.
enum SourceError: Error, CustomStringConvertible {
    case needsCredentials(String)
    case blocked(String)
    case badResponse(Int)
    case malformed(String)

    var description: String {
        switch self {
        case let .needsCredentials(s): return "\(s) needs credentials — add them in Settings"
        case let .blocked(s): return "\(s) refused the request"
        case let .badResponse(code): return "HTTP \(code)"
        case let .malformed(what): return "unexpected response shape: \(what)"
        }
    }
}

protocol ImageSource: Sendable {
    /// Stable key used in preferences and on disk.
    var id: String { get }
    var displayName: String { get }
    /// Shown in Settings so it's obvious which sources need setup.
    var needsCredentials: Bool { get }

    func fetch() async throws -> [RemoteImage]
}

extension ImageSource {
    var needsCredentials: Bool { false }
}

/// Shared HTTP plumbing. Kept deliberately small — every source is just a GET
/// and a decode.
enum Net {
    /// Sources are picky about this in different ways: Bing and ArtStation want
    /// something browser-shaped, Reddit wants the platform:app:version form.
    static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    static let redditUA = "macos:com.kamenlevi.varietyv2:0.1.0 (by /u/kamenlevi)"

    static func data(_ url: URL, ua: String = browserUA, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.badResponse(http.statusCode)
        }
        return data
    }

    static func json<T: Decodable>(_ type: T.Type, from url: URL, ua: String = browserUA,
                                   headers: [String: String] = [:]) async throws -> T {
        let data = try await data(url, ua: ua, headers: headers)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SourceError.malformed("\(error)")
        }
    }
}
