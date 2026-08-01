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

    /// How many unseen images a given source row is sitting on. A row at the cap
    /// is skipped, which is what stops one prolific source dominating.
    ///
    /// Counted per *row* (`originSourceID`), matching Variety, where the cap is
    /// per downloader instance. Counting by filename prefix meant every
    /// Wallhaven search shared a single allowance of ten, so enabling a second
    /// one starved the first rather than adding to it.
    func unseenCount(forSource sourceID: String) -> Int {
        unseenFiles().filter { metadata(for: $0)?.originSourceID == sourceID }.count
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

    // MARK: - Ownership

    /// Whether this app is the one that put `file` in the download folder.
    ///
    /// Every download writes a JSON sidecar next to the image (`writeMetadata`),
    /// and nothing else does, so sidecar presence is a reliable marker of
    /// "we created this".
    ///
    /// This gate exists because the download folder is user-settable from
    /// Preferences. Without it, pointing it at an existing picture folder means
    /// the quota sweep starts deleting images the user has never heard of —
    /// which it did, unrecoverably, because it used `removeItem` rather than
    /// the Trash.
    private func isOwned(_ file: URL) -> Bool {
        fm.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("json").path)
    }

    /// Downloaded images this app actually created, newest first.
    func ownedDownloads() -> [URL] { downloaded().filter(isOwned) }

    /// Folders whose contents must never be swept, whatever the setting says.
    ///
    /// Choosing one of these as the download folder is a misconfiguration
    /// rather than an instruction to delete its contents.
    private static let protectedRoots: [URL] = {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [home]
            + ["Pictures", "Documents", "Desktop", "Downloads", "Movies", "Music"]
                .map { home.appendingPathComponent($0) }
    }()

    /// True when the download folder is somewhere it would be reckless to
    /// delete from — the home directory itself, or one of the standard user
    /// folders. Subfolders of these are fine; it is the folders themselves that
    /// are off limits.
    var downloadFolderIsProtected: Bool {
        let folder = settings.downloadFolderURL.standardizedFileURL
        return Self.protectedRoots.contains { $0.standardizedFileURL == folder }
    }

    // MARK: - Quota

    /// Variety bounds the Downloaded folder by total size in megabytes, not by
    /// file count, and never touches Favorites. Oldest go first.
    ///
    /// Only images this app downloaded are considered, and they go to the Trash
    /// rather than being unlinked, so a misconfigured download folder costs the
    /// user nothing they cannot get back.
    func enforceQuota() {
        guard settings.quotaEnabled, !downloadFolderIsProtected else { return }
        let limit = Int64(settings.quotaSize) * 1024 * 1024

        var files = ownedDownloads().reversed().map { url -> (URL, Int64) in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return (url, Int64(size))
        }
        var total = files.reduce(Int64(0)) { $0 + $1.1 }

        while total > limit, !files.isEmpty {
            let (url, size) = files.removeFirst()
            try? fm.trashItem(at: url, resultingItemURL: nil)
            try? fm.trashItem(at: url.deletingPathExtension().appendingPathExtension("json"),
                              resultingItemURL: nil)
            total -= size
        }
    }

    // MARK: - Bulk removal

    /// How many downloaded images came from each source row, for the UI.
    ///
    /// Keyed by `originSourceID` — the row of the Images table, e.g.
    /// `unsplash|black and white` — because that is what the rotation filters
    /// on. Keying on the filename prefix instead named only the *service*, so
    /// two Unsplash searches collapsed into one bucket and removing either one
    /// removed both.
    ///
    /// Images predating provenance have no row to attribute them to and are
    /// grouped under `legacyBucket`, which is also what the rotation excludes.
    func downloadCountsBySource() -> [(source: String, count: Int, bytes: Int64)] {
        var tally: [String: (count: Int, bytes: Int64)] = [:]
        for file in ownedDownloads() {
            let source = metadata(for: file)?.originSourceID ?? Self.legacyBucket
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let existing = tally[source] ?? (0, 0)
            tally[source] = (existing.count + 1, existing.bytes + size)
        }
        return tally
            .map { (source: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { $0.count > $1.count }
    }

    /// Bucket for downloads with no recorded source row. These are excluded
    /// from rotation, so the Library tab needs to be able to name and clear
    /// them — otherwise they are invisible disk usage.
    static let legacyBucket = "(unknown source)"

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
        guard !downloadFolderIsProtected else { return 0 }

        var removed = 0
        for file in ownedDownloads() {
            if let source {
                // Matched on the source row, the same key the Library tab
                // tallies by, so "Remove" clears exactly the bucket shown.
                let origin = metadata(for: file)?.originSourceID ?? Self.legacyBucket
                guard origin == source else { continue }
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
