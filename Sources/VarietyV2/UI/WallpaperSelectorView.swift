import AppKit
import SwiftUI

/// Variety's Wallpaper Selector: everything available, browsable, with search.
///
/// The Linux version is a grid of every image from every enabled source. Search
/// and source filtering are added here because the collection is large enough
/// that scrolling alone is not a way to find anything.
struct WallpaperSelectorView: View {

    let rotator: Rotator

    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var files: [URL] = []
    @State private var loading = true

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", favorites = "Favorites", downloaded = "Downloaded"
        case fetched = "Fetched", folders = "My Folders"
        var id: String { rawValue }
    }

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                Spacer()

                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(10)

            Divider()

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Nothing here yet" : "No matches",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(query.isEmpty
                                      ? "Images appear as they are downloaded, or once you add a folder in Preferences."
                                      : "No image name matches “\(query)”."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(visible, id: \.self) { file in
                            Thumbnail(file: file) {
                                Task { await rotator.show(file: file) }
                            }
                        }
                    }
                    .padding(10)
                }
            }

            Divider()
            HStack {
                Text("\(visible.count) of \(files.count) images")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reload") { load() }
            }
            .padding(8)
        }
        .task { load() }
    }

    private var visible: [URL] {
        let scoped: [URL]
        switch scope {
        case .all: scoped = files
        case .favorites: scoped = rotator.favoritesForDisplay()
        case .downloaded: scoped = rotator.recentForDisplay()
        case .fetched: scoped = rotator.fetchedForDisplay()
        case .folders: scoped = SourceRegistry.activeLocalFiles(settings: rotator.settings)
        }
        guard !query.isEmpty else { return scoped }
        return scoped.filter {
            $0.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
    }

    private func load() {
        loading = true
        // Folder scanning can walk thousands of files; keep it off the main
        // thread so the window paints immediately.
        Task.detached {
            let found = await rotator.allSelectable()
            await MainActor.run {
                files = found
                loading = false
            }
        }
    }
}

/// Grid cell. Thumbnails are decoded at cell size rather than full resolution.
private struct Thumbnail: View {
    let file: URL
    let action: () -> Void

    @State private var image: NSImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 120)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(file.lastPathComponent)
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let url = file
        let loaded: NSImage? = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 400,
                  ] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
        image = loaded
    }
}
