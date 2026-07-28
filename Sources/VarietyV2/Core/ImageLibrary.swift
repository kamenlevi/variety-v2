import AppKit
import Foundation

/// Images on disk and the keep/discard workflow.
///
/// Variety keeps three folders — Downloaded, Fetched and Favorites — and
/// favouriting *copies* or *moves* depending on where the image came from
/// (`favorites_operations`). That distinction is preserved: a fetched image is
/// moved because the Fetched folder is a scratch area, whereas a downloaded one
/// is copied because it is still wanted in the rotation pool.
final class ImageLibrary {

    private let settings: Settings
    private let fm = FileManager.default

    init(settings: Settings) {
        self.settings = settings
        for folder in [settings.downloadFolderURL, settings.favoritesFolderURL, settings.fetchedFolderURL] {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        loadLedger()
    }

    // MARK: - Ledger

    private struct Ledger: Codable {
        /// Every image id ever downloaded, so nothing is fetched twice.
        var seen: Set<String> = []
        var banished: Set<String> = []
        /// Files downloaded but not yet shown as wallpaper.
        ///
        /// Variety keeps this per downloader and stops fetching from a source
        /// once it holds `MAX_UNSEEN_PER_DOWNLOADER` (10) of them, then shows
        /// unseen images in preference to the general pool. That is what keeps
        /// its download folder from filling up with images you never look at.
        var unseen: Set<String> = []
    }

    private var ledger = Ledger()
    private var ledgerURL: URL { settings.downloadFolderURL.appendingPathComponent(".ledger.json") }

    private func loadLedger() {
        guard let data = try? Data(contentsOf: ledgerURL),
              let decoded = try? JSONDecoder().decode(Ledger.self, from: data) else { return }
        ledger = decoded
    }

    private func saveLedger() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: ledgerURL, options: .atomic)
    }

    func hasSeen(_ id: String) -> Bool { ledger.seen.contains(id) || ledger.banished.contains(id) }

    // MARK: - Unseen buffer

    /// Variety's `MAX_UNSEEN_PER_DOWNLOADER`.
    static let maxUnseenPerSource = 10

    /// Downloaded-but-not-yet-shown files that still exist on disk.
    func unseenFiles() -> [URL] {
        ledger.unseen
            .map { URL(fileURLWithPath: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    /// How many unseen images a given source is sitting on. A source at the cap
    /// is skipped, which is what stops one prolific source dominating.
    func unseenCount(forSource sourceID: String) -> Int {
        let prefix = sourceID.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        return unseenFiles().filter { $0.lastPathComponent.hasPrefix(prefix) }.count
    }

    /// Called when an image is actually displayed.
    func markSeen(_ file: URL) {
        guard ledger.unseen.remove(file.path) != nil else { return }
        saveLedger()
    }

    private func markUnseen(_ file: URL) {
        ledger.unseen.insert(file.path)
        // Drop entries whose files have gone, so the set does not grow forever.
        ledger.unseen = Set(unseenFiles().map(\.path))
    }

    // MARK: - Download

    @discardableResult
    func download(_ image: RemoteImage, screenSize: CGSize) async throws -> URL? {
        guard !hasSeen(image.id) else { return nil }

        let filter = ImageFilter(settings: settings)
        // Cheap rejection before spending the bandwidth.
        guard filter.passesNameCheck(image.imageURL.lastPathComponent) else { return nil }

        let data = try await Net.data(image.imageURL)

        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide >= 800, rep.pixelsHigh >= 600 else {
            ledger.banished.insert(image.id)
            saveLedger()
            return nil
        }

        let ext = image.imageURL.pathExtension.isEmpty ? "jpg" : image.imageURL.pathExtension
        let safeID = image.id
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        let destination = settings.downloadFolderURL.appendingPathComponent("\(safeID).\(ext)")

        try data.write(to: destination, options: .atomic)

        // Full criteria need the decoded image, so they run after the write and
        // discard on failure. Cheaper than decoding twice.
        guard filter.passes(imageAt: destination, screenSize: screenSize) else {
            try? fm.removeItem(at: destination)
            ledger.banished.insert(image.id)
            saveLedger()
            return nil
        }

        writeMetadata(for: image, at: destination)
        ledger.seen.insert(image.id)
        markUnseen(destination)
        saveLedger()
        return destination
    }

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

    func downloaded() -> [URL] { contents(of: settings.downloadFolderURL) }
    func favorites() -> [URL] { contents(of: settings.favoritesFolderURL) }
    func fetched() -> [URL] { contents(of: settings.fetchedFolderURL) }

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

    /// Which origin bucket a file belongs to, for `favorites_operations`.
    private func origin(of file: URL) -> String {
        let parent = file.deletingLastPathComponent().standardizedFileURL
        if parent == settings.downloadFolderURL.standardizedFileURL { return "Downloaded" }
        if parent == settings.fetchedFolderURL.standardizedFileURL { return "Fetched" }
        return "Others"
    }

    @discardableResult
    func favorite(_ file: URL) -> URL? {
        guard !isFavorite(file) else { return file }

        let bucket = origin(of: file)
        let operation = settings.favoritesOperations
            .first { $0.origin == bucket }?.operation ?? .copy

        var destination = settings.favoritesFolderURL.appendingPathComponent(file.lastPathComponent)
        // Don't clobber a different image that happens to share a name.
        var attempt = 1
        while fm.fileExists(atPath: destination.path) {
            if (try? Data(contentsOf: destination)) == (try? Data(contentsOf: file)) { return destination }
            let stem = file.deletingPathExtension().lastPathComponent
            destination = settings.favoritesFolderURL
                .appendingPathComponent("\(stem)-\(attempt).\(file.pathExtension)")
            attempt += 1
        }

        do {
            switch operation {
            case .copy: try fm.copyItem(at: file, to: destination)
            case .move: try fm.moveItem(at: file, to: destination)
            }
            let sidecar = file.deletingPathExtension().appendingPathExtension("json")
            if fm.fileExists(atPath: sidecar.path) {
                let target = destination.deletingPathExtension().appendingPathExtension("json")
                switch operation {
                case .copy: try? fm.copyItem(at: sidecar, to: target)
                case .move: try? fm.moveItem(at: sidecar, to: target)
                }
            }
            return destination
        } catch {
            NSLog("VarietyV2: could not favorite \(file.lastPathComponent): \(error)")
            return nil
        }
    }

    func isFavorite(_ file: URL) -> Bool {
        file.deletingLastPathComponent().standardizedFileURL
            == settings.favoritesFolderURL.standardizedFileURL
    }

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

    // MARK: - Quota

    /// Variety bounds the Downloaded folder by total size in megabytes, not by
    /// file count, and never touches Favorites. Oldest go first.
    func enforceQuota() {
        guard settings.quotaEnabled else { return }
        let limit = Int64(settings.quotaSize) * 1024 * 1024

        var files = downloaded().reversed().map { url -> (URL, Int64) in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return (url, Int64(size))
        }
        var total = files.reduce(Int64(0)) { $0 + $1.1 }

        while total > limit, !files.isEmpty {
            let (url, size) = files.removeFirst()
            try? fm.removeItem(at: url)
            try? fm.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
            total -= size
        }
    }

    // MARK: - Bulk removal

    /// How many downloaded images came from each source, for the UI.
    /// Keyed by the source prefix embedded in the filename.
    func downloadCountsBySource() -> [(source: String, count: Int, bytes: Int64)] {
        var tally: [String: (count: Int, bytes: Int64)] = [:]
        for file in downloaded() {
            let name = file.lastPathComponent
            // Filenames are "<sourceid>-<rest>", from RemoteImage.id.
            let source = name.split(separator: "-").first.map(String.init) ?? "other"
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let existing = tally[source] ?? (0, 0)
            tally[source] = (existing.count + 1, existing.bytes + size)
        }
        return tally
            .map { (source: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { $0.count > $1.count }
    }

    /// Removes downloaded images, optionally only those from one source.
    ///
    /// Favourites are never touched — they live in a different folder by
    /// design, which is the whole point of favouriting.
    ///
    /// - Parameter banish: when true the images are also recorded as rejected,
    ///   so the same pictures are not downloaded again on the next refill.
    ///   Without this, deleting is futile — the sources would simply hand them
    ///   back.
    @discardableResult
    func clearDownloads(source: String? = nil, banish: Bool = true) -> Int {
        var removed = 0
        for file in downloaded() {
            if let source {
                let prefix = file.lastPathComponent.split(separator: "-").first.map(String.init)
                guard prefix == source else { continue }
            }

            if banish, let meta = metadata(for: file) {
                ledger.banished.insert(meta.id)
                ledger.seen.remove(meta.id)
            }
            try? fm.trashItem(at: file, resultingItemURL: nil)
            let sidecar = file.deletingPathExtension().appendingPathExtension("json")
            try? fm.trashItem(at: sidecar, resultingItemURL: nil)
            removed += 1
        }
        saveLedger()
        return removed
    }

    /// Removes specific files — the Wallpaper Selector's delete action.
    @discardableResult
    func remove(_ files: [URL], banish: Bool = true) -> Int {
        var removed = 0
        for file in files {
            // Favourites are removed only from the favourites folder, never
            // silently banished — the user explicitly kept those.
            if banish, !isFavorite(file), let meta = metadata(for: file) {
                ledger.banished.insert(meta.id)
                ledger.seen.remove(meta.id)
            }
            try? fm.trashItem(at: file, resultingItemURL: nil)
            let sidecar = file.deletingPathExtension().appendingPathExtension("json")
            try? fm.trashItem(at: sidecar, resultingItemURL: nil)
            removed += 1
        }
        saveLedger()
        return removed
    }

    /// Forgets every rejection, so previously trashed images can return.
    func resetBanished() {
        ledger.banished.removeAll()
        saveLedger()
    }

    var banishedCount: Int { ledger.banished.count }

    var downloadedBytes: Int64 {
        downloaded().reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}
