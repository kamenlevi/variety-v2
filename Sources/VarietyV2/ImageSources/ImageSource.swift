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

    /// Pixel dimensions when the service reports them. Variety uses these to
    /// reject unsuitable images *before* downloading — the whole point of
    /// asking the API for sizes rather than measuring files afterwards.
    var pixelWidth: Int?
    var pixelHeight: Int?

    /// Which row of the Images table produced this, e.g. `wallhaven|nature`.
    ///
    /// Without it, disabling a source cannot remove its already-downloaded
    /// images from rotation: the filename prefix only identifies the *service*,
    /// so two Wallhaven searches are indistinguishable, and turning one off
    /// would either keep showing it or wrongly drop the other.
    var originSourceID: String?

    /// 0...1 shape agreement with the screen; 1 means it will crop perfectly.
    /// Unknown dimensions score neutral rather than last, so sources that do
    /// not report sizes are not silently starved.
    var aspectMatch: Double {
        guard let pixelWidth, let pixelHeight else { return 0.75 }
        return ScreenGeometry.aspectMatch(width: pixelWidth, height: pixelHeight)
    }

    func fitsScreen(settings: Settings) -> Bool {
        guard let pixelWidth, let pixelHeight else { return true }
        return ScreenGeometry.sizeOK(width: pixelWidth, height: pixelHeight, settings: settings)
    }

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
    /// Reddit asks that the User-Agent identify the *application*. It must not
    /// name an individual account: every install would then claim to be that
    /// person, so one user's rate limiting or ban would apply to everybody.
    static let redditUA = "macos:org.varietywalls.variety:0.1.0"

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
