import AppKit
import Foundation

/// Downloaded images on disk, plus the keep/discard workflow that is the point
/// of Variety: favourites are moved somewhere permanent, trashed images are
/// remembered so they never come back.
final class ImageLibrary {

    private let settings: Settings
    private let fm = FileManager.default

    init(settings: Settings) {
        self.settings = settings
        try? fm.createDirectory(at: settings.expandedDownloadFolder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: settings.expandedFavoritesFolder, withIntermediateDirectories: true)
        loadLedger()
    }

    // MARK: - Ledger
    //
    // Identity is the source-provided id, not the file path, so an image stays
    // recognised after being favourited (and therefore moved) or deleted.

    private struct Ledger: Codable {
        var seen: Set<String> = []
        var banished: Set<String> = []
    }

    private var ledger = Ledger()

    private var ledgerURL: URL {
        settings.expandedDownloadFolder.appendingPathComponent(".ledger.json")
    }

    private func loadLedger() {
        guard let data = try? Data(contentsOf: ledgerURL),
              let decoded = try? JSONDecoder().decode(Ledger.self, from: data) else { return }
        ledger = decoded
    }

    private func saveLedger() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: ledgerURL, options: .atomic)
    }

    // MARK: - Download

    /// Downloads `image` unless it has been seen or trashed before.
    /// Returns the local file, or nil if it was skipped.
    func download(_ image: RemoteImage) async throws -> URL? {
        guard !ledger.banished.contains(image.id), !ledger.seen.contains(image.id) else { return nil }

        let data = try await Net.data(image.imageURL)

        // Reject anything that isn't a decodable image of usable size: sources
        // occasionally hand back HTML error pages or tiny placeholders with an
        // image content-type.
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide >= 800, rep.pixelsHigh >= 600 else {
            ledger.banished.insert(image.id)
            saveLedger()
            return nil
        }

        let ext = image.imageURL.pathExtension.isEmpty ? "jpg" : image.imageURL.pathExtension
        let safeID = image.id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        let destination = settings.expandedDownloadFolder.appendingPathComponent("\(safeID).\(ext)")

        try data.write(to: destination, options: .atomic)
        writeMetadata(for: image, at: destination)

        ledger.seen.insert(image.id)
        saveLedger()
        return destination
    }

    /// Sidecar JSON so attribution survives independently of the image file —
    /// needed for "view source" and for the quote/author line.
    private func writeMetadata(for image: RemoteImage, at file: URL) {
        let sidecar = file.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? JSONEncoder().encode(image) else { return }
        try? data.write(to: sidecar, options: .atomic)
    }

    func metadata(for file: URL) -> RemoteImage? {
        let sidecar = file.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        return try? JSONDecoder().decode(RemoteImage.self, from: data)
    }

    // MARK: - Contents

    /// Downloaded images, newest first.
    func downloaded() -> [URL] {
        contents(of: settings.expandedDownloadFolder)
    }

    func favorites() -> [URL] {
        contents(of: settings.expandedFavoritesFolder)
    }

    private func contents(of directory: URL) -> [URL] {
        let entries = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        return entries
            .filter { ["jpg", "jpeg", "png", "webp", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
    }

    // MARK: - Keep / discard

    /// Moves an image into the favourites folder, where pruning never touches it.
    @discardableResult
    func favorite(_ file: URL) -> URL? {
        let destination = settings.expandedFavoritesFolder.appendingPathComponent(file.lastPathComponent)
        guard !fm.fileExists(atPath: destination.path) else { return destination }
        do {
            try fm.moveItem(at: file, to: destination)
            let sidecar = file.deletingPathExtension().appendingPathExtension("json")
            if fm.fileExists(atPath: sidecar.path) {
                try? fm.moveItem(at: sidecar,
                                 to: destination.deletingPathExtension().appendingPathExtension("json"))
            }
            return destination
        } catch {
            return nil
        }
    }

    func isFavorite(_ file: URL) -> Bool {
        file.deletingLastPathComponent().standardizedFileURL
            == settings.expandedFavoritesFolder.standardizedFileURL
    }

    /// Deletes an image and records its id so the source never offers it again.
    func trash(_ file: URL) {
        if let meta = metadata(for: file) {
            ledger.banished.insert(meta.id)
            ledger.seen.remove(meta.id)
            saveLedger()
        }
        try? fm.trashItem(at: file, resultingItemURL: nil)
        let sidecar = file.deletingPathExtension().appendingPathExtension("json")
        try? fm.trashItem(at: sidecar, resultingItemURL: nil)
    }

    /// Keeps the download folder bounded. Favourites live elsewhere and are
    /// never considered here.
    func prune() {
        let files = downloaded()
        guard files.count > settings.keepDownloaded else { return }
        for file in files.dropFirst(settings.keepDownloaded) {
            try? fm.removeItem(at: file)
            try? fm.removeItem(at: file.deletingPathExtension().appendingPathExtension("json"))
        }
    }
}
