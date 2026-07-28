import AppKit
import SwiftUI

/// Search a service for a subject and add it as a rotating source.
///
/// Variety's equivalent is its per-service Add dialogs, which take a query and
/// offer a Validate button that reports how many results exist. This does the
/// same but shows the results, because "does this query give me good
/// wallpapers?" is a question a thumbnail grid answers and a number does not.
///
/// The distinction that matters: adding a source is not a one-off download.
/// The query is stored and re-queried forever, so "japan" keeps supplying new
/// Japan wallpapers as the service gains them.
struct ImageSearchView: View {

    let settings: Settings
    /// Called with the source to add to the rotation.
    let onAdd: (Source) -> Void

    @State private var service: Service = .wallhaven
    @State private var query = ""
    @State private var results: [RemoteImage] = []
    @State private var state: SearchState = .idle
    @State private var searchTask: Task<Void, Never>?

    enum SearchState: Equatable {
        case idle, searching
        case done(count: Int)
        case failed(String)
    }

    enum Service: String, CaseIterable, Identifiable {
        case wallhaven = "Wallhaven"
        case unsplash = "Unsplash"
        case reddit = "Subreddit"
        case artstation = "ArtStation"
        var id: String { rawValue }

        var kind: Source.Kind {
            switch self {
            case .wallhaven: return .wallhaven
            case .unsplash: return .unsplash
            case .reddit: return .reddit
            case .artstation: return .artstation
            }
        }

        var placeholder: String {
            switch self {
            case .wallhaven: return "e.g. japan, mountains, minimal"
            case .unsplash: return "e.g. japan, architecture"
            case .reddit: return "subreddit name, e.g. EarthPorn"
            case .artstation: return "artist username"
            }
        }

        var needsCredentials: Bool { self == .unsplash }
    }

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            resultsArea
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $service) {
                ForEach(Service.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: service) { _, _ in results = []; state = .idle }

            HStack {
                TextField(service.placeholder, text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("Search", action: search)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.isEmpty && service != .artstation)
            }

            if service.needsCredentials, settings.unsplashAccessKey.isEmpty {
                HStack(spacing: 4) {
                    Label("Unsplash needs a free access key — Preferences → Downloading.",
                          systemImage: "exclamationmark.triangle")
                    Link("Get one", destination:
                        URL(string: "https://unsplash.com/oauth/applications")!)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if service == .wallhaven {
                Text("Wallhaven matches tags, not phrases — several words are combined automatically. Its General category leans heavily towards digital and fantasy art; use Unsplash for photography.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("Only images that fit your \(ScreenGeometry.description) display are shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        switch state {
        case .searching:
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle",
                                   description: Text(message))

        case .done(0):
            ContentUnavailableView("No results", systemImage: "magnifyingglass",
                                   description: Text("Nothing matched “\(query)” at a size that fits your screen. Try a broader term."))

        case .idle:
            ContentUnavailableView("Search for a subject", systemImage: "magnifyingglass",
                                   description: Text("Type something like “japan” to preview what this source would supply."))

        case .done:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(results, id: \.id) { image in
                        SearchThumbnail(image: image)
                    }
                }
                .padding(10)
            }
        }
    }

    private var footer: some View {
        HStack {
            if case let .done(count) = state, count > 0 {
                Text("\(count) matching image\(count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add as a source") {
                onAdd(Source(enabled: true, kind: service.kind, location: query))
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canAdd)
        }
        .padding(10)
    }

    private var canAdd: Bool {
        if service == .artstation { return true }
        guard !query.isEmpty else { return false }
        if case .done(let count) = state { return count > 0 }
        return false
    }

    // MARK: - Searching

    private func search() {
        searchTask?.cancel()
        state = .searching
        results = []

        let source = Source(enabled: true, kind: service.kind, location: query)
        let settings = settings

        searchTask = Task {
            guard let downloader = SourceRegistry.downloader(for: source, settings: settings) else {
                await MainActor.run {
                    state = .failed(service.needsCredentials
                                    ? "\(service.rawValue) needs credentials before it can be searched."
                                    : "Internet access is switched off in Preferences.")
                }
                return
            }

            do {
                let found = try await downloader.fetch()
                guard !Task.isCancelled else { return }

                // Same screen filter the rotation applies, so the preview is an
                // honest sample of what would actually be used.
                let fitting = found
                    .filter { $0.fitsScreen(settings: settings) }
                    .sorted { $0.aspectMatch > $1.aspectMatch }

                await MainActor.run {
                    results = Array(fitting.prefix(60))
                    state = .done(count: fitting.count)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { state = .failed("\(error)") }
            }
        }
    }
}

/// One search result. Loads the image at thumbnail size only.
private struct SearchThumbnail: View {
    let image: RemoteImage
    @State private var preview: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                if let preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 115)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 5))

            if let width = image.pixelWidth, let height = image.pixelHeight {
                Text("\(width)×\(height)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .help(image.title ?? image.imageURL.lastPathComponent)
        .task { await load() }
    }

    private func load() async {
        let url = image.imageURL
        let loaded: NSImage? = await Task.detached(priority: .utility) {
            // Fetch and downsample rather than decoding a full 4K wallpaper for
            // a 190pt cell — a grid of sixty would otherwise be enormous.
            guard let data = try? await Net.data(url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 400,
                  ] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
        preview = loaded
    }
}
