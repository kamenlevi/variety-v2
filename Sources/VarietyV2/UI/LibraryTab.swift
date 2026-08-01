import AppKit
import SwiftUI

/// Managing what has already been downloaded.
///
/// Variety has no equivalent screen — on Linux you are expected to open the
/// Downloaded folder in a file manager. That is a poor answer on its own,
/// because deleting the files is not enough: the sources will hand the same
/// images straight back on the next refill unless they are also recorded as
/// rejected. Clearing here does both.
struct LibraryTab: View {

    let rotator: Rotator
    @State private var breakdown: [(source: String, count: Int, bytes: Int64)] = []
    @State private var confirming: ConfirmTarget?
    @State private var status: String?

    struct ConfirmTarget: Identifiable {
        let source: String?
        var id: String { source ?? "__all__" }
        var label: String { source ?? "everything" }
        let count: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Downloaded images").font(.headline)
                Spacer()
                Button("Refresh") { reload() }
            }

            if breakdown.isEmpty {
                ContentUnavailableView("Nothing downloaded yet",
                                       systemImage: "tray",
                                       description: Text("Images appear here as sources are fetched."))
                    .frame(maxHeight: 220)
            } else {
                List {
                    ForEach(breakdown, id: \.source) { row in
                        HStack {
                            Text(displayName(row.source))
                            Spacer()
                            Text("\(row.count) image\(row.count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                            Text(format(row.bytes))
                                .foregroundStyle(.tertiary)
                                .frame(width: 70, alignment: .trailing)
                            Button("Remove") {
                                confirming = ConfirmTarget(source: row.source, count: row.count)
                            }
                        }
                    }
                }
                .frame(minHeight: 200)
            }

            HStack {
                Button("Remove All Downloads", role: .destructive) {
                    confirming = ConfirmTarget(source: nil, count: breakdown.reduce(0) { $0 + $1.count })
                }
                .disabled(breakdown.isEmpty)

                Button("Open Downloads Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [rotator.settings.downloadFolderURL])
                }
                Spacer()
            }

            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Rejected images").font(.headline)
                Text("\(rotator.banishedCount) image\(rotator.banishedCount == 1 ? "" : "s") will never be downloaded again — trashed images, and anything that failed the filters.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Allow Rejected Images Again") {
                    rotator.resetBanished()
                    status = "Rejections cleared. Previously removed images may return."
                }
                .disabled(rotator.banishedCount == 0)
            }

            Spacer()
        }
        .padding()
        .task { reload() }
        .alert(item: $confirming) { target in
            Alert(
                title: Text("Remove \(target.count) image\(target.count == 1 ? "" : "s")?"),
                message: Text("They go to the Trash, and will not be downloaded again. Favourites are not affected."),
                primaryButton: .destructive(Text("Remove")) {
                    Task {
                        let removed = await rotator.clearDownloads(source: target.source)
                        status = "Moved \(removed) image\(removed == 1 ? "" : "s") to the Trash."
                        reload()
                    }
                },
                secondaryButton: .cancel())
        }
    }

    private func reload() {
        breakdown = rotator.downloadCountsBySource()
    }

    /// Buckets are keyed by source row — `kind|location`, e.g.
    /// `unsplash|black and white` — so both halves need naming: the service in
    /// full, and the search term that distinguishes one row from another of the
    /// same service.
    private func displayName(_ source: String) -> String {
        if source == ImageLibrary.legacyBucket {
            return "Unknown source (not in rotation)"
        }

        let parts = source.split(separator: "|", maxSplits: 1).map(String.init)
        let service = serviceName(parts.first ?? source)
        guard let location = parts.dropFirst().first, !location.isEmpty else { return service }
        return "\(service) — \(location)"
    }

    private func serviceName(_ kind: String) -> String {
        switch kind {
        case "artstation": return "ArtStation"
        case "wallhaven": return "Wallhaven"
        case "bing": return "Bing Photo of the Day"
        case "earthview": return "Google Earth View"
        case "apod": return "NASA APOD"
        case "unsplash": return "Unsplash"
        case "reddit": return "Reddit"
        case "mediarss", "feed": return "RSS feed"
        default: return kind.capitalized
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
