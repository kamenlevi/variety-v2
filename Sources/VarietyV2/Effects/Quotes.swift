import Foundation

struct Quote: Codable, Hashable {
    let text: String
    let author: String?
}

/// Supplies quotes for the overlay.
///
/// Variety's original sources are largely gone — it scrapes Goodreads, and
/// `api.quotable.io`, the obvious modern replacement, no longer resolves. Two
/// live services are tried in turn, and a small bundled set backstops both so
/// the feature still works offline or when a service rate-limits us.
enum QuoteProvider {

    static func random() async -> Quote {
        if let quote = await zenQuotes() { return quote }
        if let quote = await quotableMirror() { return quote }
        return offline.randomElement()!
    }

    // MARK: - Online

    private struct ZenQuote: Decodable { let q: String; let a: String? }

    private static func zenQuotes() async -> Quote? {
        // Free tier is rate-limited to a handful of requests per 30s, which is
        // ample at one per wallpaper change.
        guard let url = URL(string: "https://zenquotes.io/api/random"),
              let quotes = try? await Net.json([ZenQuote].self, from: url),
              let first = quotes.first
        else { return nil }
        return Quote(text: first.q, author: first.a)
    }

    private struct MirrorResponse: Decodable {
        struct Wrapper: Decodable {
            struct Author: Decodable { let name: String? }
            let content: String
            let author: Author?
        }
        let quote: Wrapper
    }

    /// Community-run continuation of the retired quotable.io API.
    private static func quotableMirror() async -> Quote? {
        guard let url = URL(string: "https://api.quotable.kurokeita.dev/api/quotes/random"),
              let response = try? await Net.json(MirrorResponse.self, from: url)
        else { return nil }
        return Quote(text: response.quote.content, author: response.quote.author?.name)
    }

    // MARK: - Offline

    /// Deliberately short: enough that the feature is never dead, not so much
    /// that it becomes a curated collection to maintain.
    static let offline: [Quote] = [
        Quote(text: "Nothing endures but change.", author: "Heraclitus"),
        Quote(text: "The cautious seldom err.", author: "Confucius"),
        Quote(text: "Simplicity is the ultimate sophistication.", author: "Leonardo da Vinci"),
        Quote(text: "We are what we repeatedly do.", author: "Will Durant"),
        Quote(text: "The obstacle is the way.", author: "Marcus Aurelius"),
        Quote(text: "Everything should be made as simple as possible, but no simpler.", author: "Albert Einstein"),
        Quote(text: "What we observe is not nature itself, but nature exposed to our method of questioning.", author: "Werner Heisenberg"),
        Quote(text: "The world is full of magic things, patiently waiting for our senses to grow sharper.", author: "W. B. Yeats"),
    ]
}
