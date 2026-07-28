import Foundation

struct Quote: Codable, Hashable {
    let text: String
    let author: String?
    /// Which provider it came from, so the Quotes tab's per-source toggles work.
    var sourceName: String = ""
    var link: String?
}

/// Supplies quotes, honouring Variety's Quotes tab filters: tag and author
/// restrictions, a maximum length, and per-source enable/disable.
///
/// Variety's own sources are largely gone — it scrapes Goodreads, and the
/// obvious modern replacement `api.quotable.io` no longer resolves. Two live
/// services are used instead, with a bundled set as a backstop so the feature
/// works offline.
enum QuoteProvider {

    static let allSourceNames = ["ZenQuotes", "Quotable", "Built-in"]

    static func random(settings: Settings) async -> Quote? {
        let enabled = allSourceNames.filter { !settings.quotesDisabledSources.contains($0) }
        guard !enabled.isEmpty else { return nil }

        // A few attempts, because the filters can reject a quote and the online
        // services hand back one at a time.
        for _ in 0..<6 {
            guard let candidate = await fetchOne(from: enabled.randomElement()!) else { continue }
            if accepts(candidate, settings: settings) { return candidate }
        }

        // Fall back to anything from the bundled set that passes, then to
        // nothing rather than showing a quote the user filtered out.
        return offline.filter { accepts($0, settings: settings) }.randomElement()
    }

    /// Applies the Quotes tab's "Sources and filtering" section.
    static func accepts(_ quote: Quote, settings: Settings) -> Bool {
        if quote.text.count > settings.quotesMaxLength { return false }

        let authors = splitTerms(settings.quotesAuthors)
        if !authors.isEmpty {
            let author = (quote.author ?? "").lowercased()
            guard authors.contains(where: { author.contains($0) }) else { return false }
        }

        let tags = splitTerms(settings.quotesTags)
        if !tags.isEmpty {
            // No live service exposes usable tags any more, so tags are matched
            // against the quote text — a lenient reading of the original intent
            // rather than silently ignoring the field.
            let text = quote.text.lowercased()
            guard tags.contains(where: { text.contains($0) }) else { return false }
        }

        return true
    }

    private static func splitTerms(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func fetchOne(from source: String) async -> Quote? {
        switch source {
        case "ZenQuotes": return await zenQuotes()
        case "Quotable": return await quotableMirror()
        default: return offline.randomElement()
        }
    }

    // MARK: - Online

    private struct ZenQuote: Decodable { let q: String; let a: String? }

    private static func zenQuotes() async -> Quote? {
        guard let url = URL(string: "https://zenquotes.io/api/random"),
              let quotes = try? await Net.json([ZenQuote].self, from: url),
              let first = quotes.first
        else { return nil }
        return Quote(text: first.q, author: first.a, sourceName: "ZenQuotes")
    }

    private struct MirrorResponse: Decodable {
        struct Wrapper: Decodable {
            struct Author: Decodable { let name: String? }
            let content: String
            let author: Author?
        }
        let quote: Wrapper
    }

    private static func quotableMirror() async -> Quote? {
        guard let url = URL(string: "https://api.quotable.kurokeita.dev/api/quotes/random"),
              let response = try? await Net.json(MirrorResponse.self, from: url)
        else { return nil }
        return Quote(text: response.quote.content,
                     author: response.quote.author?.name,
                     sourceName: "Quotable")
    }

    // MARK: - Favourites

    /// Variety keeps favourited quotes in a plain text file the user can edit.
    static func favorite(_ quote: Quote, settings: Settings) {
        let url = settings.expand(settings.quotesFavoritesFile)
        let line = "\(quote.text)\n    -- \(quote.author ?? "Unknown")\n\n"
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // MARK: - Offline

    static let offline: [Quote] = [
        Quote(text: "Nothing endures but change.", author: "Heraclitus", sourceName: "Built-in"),
        Quote(text: "The cautious seldom err.", author: "Confucius", sourceName: "Built-in"),
        Quote(text: "Simplicity is the ultimate sophistication.", author: "Leonardo da Vinci", sourceName: "Built-in"),
        Quote(text: "We are what we repeatedly do.", author: "Will Durant", sourceName: "Built-in"),
        Quote(text: "The obstacle is the way.", author: "Marcus Aurelius", sourceName: "Built-in"),
        Quote(text: "Everything should be made as simple as possible, but no simpler.", author: "Albert Einstein", sourceName: "Built-in"),
        Quote(text: "What we observe is not nature itself, but nature exposed to our method of questioning.", author: "Werner Heisenberg", sourceName: "Built-in"),
        Quote(text: "The world is full of magic things, patiently waiting for our senses to grow sharper.", author: "W. B. Yeats", sourceName: "Built-in"),
    ]
}
