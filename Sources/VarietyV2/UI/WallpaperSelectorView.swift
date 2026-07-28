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
    @State private var selected: Set<URL> = []
    @State private var confirmingDelete = false

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
                            Thumbnail(file: file,
                                      isSelected: selected.contains(file)) {
                                Task { await rotator.show(file: file) }
                            } toggleSelection: {
                                if selected.contains(file) { selected.remove(file) }
                                else { selected.insert(file) }
                            }
                            .contextMenu {
                                Button("Set as Wallpaper") {
                                    Task { await rotator.show(file: file) }
                                }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([file])
                                }
                                Divider()
                                Button("Remove", role: .destructive) {
                                    Task {
                                        await rotator.remove([file])
                                        selected.remove(file)
                                        load()
                                    }
                                }
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

                if !selected.isEmpty {
                    Text("· \(selected.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Clear") { selected.removeAll() }
                        .buttonStyle(.link)
                }

                Spacer()

                if !selected.isEmpty {
                    Button("Remove \(selected.count)", role: .destructive) {
                        confirmingDelete = true
                    }
                }
                Button("Select All Shown") { selected.formUnion(visible) }
                    .disabled(visible.isEmpty)
                Button("Reload") { load() }
            }
            .padding(8)
        }
        .task { load() }
        .alert("Remove \(selected.count) image\(selected.count == 1 ? "" : "s")?",
               isPresented: $confirmingDelete) {
            Button("Remove", role: .destructive) {
                let doomed = Array(selected)
                Task {
                    await rotator.remove(doomed)
                    selected.removeAll()
                    load()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They go to the Trash and will not be downloaded again.")
        }
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
    var isSelected: Bool = false
    let action: () -> Void
    var toggleSelection: () -> Void = {}

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
            .overlay(alignment: .topLeading) {
                // Checkbox rather than click-to-select: a plain click still
                // sets the wallpaper, which is the common action.
                Button(action: toggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.85))
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .padding(5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
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
