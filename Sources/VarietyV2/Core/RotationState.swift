import Foundation

/// What the rotation remembers between launches.
///
/// Held only in memory before, which had two visible consequences: the menu's
/// per-image section (filename, View at source, Favorites, Delete to Trash and
/// the Image submenu) was absent after every relaunch until the first
/// rotation — up to a full interval of nothing — and History was permanently
/// empty, since it only ever described the current session.
struct RotationState: Codable {
    var history: [String] = []
    var index: Int = -1
    var current: String?

    /// Bounded: history is a browsing aid, not an archive, and an unbounded
    /// list would grow for the life of the install.
    static let maxHistory = 200

    static let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/VarietyV2/state.json")

    static func load() -> RotationState {
        guard let data = try? Data(contentsOf: fileURL),
              var state = try? JSONDecoder().decode(RotationState.self, from: data)
        else { return RotationState() }

        // Files can be deleted, trashed or favourited (and so moved) between
        // launches; drop anything no longer there rather than showing gaps.
        let fm = FileManager.default
        let surviving = state.history.filter { fm.fileExists(atPath: $0) }
        if surviving.count != state.history.count {
            // Keep the index pointing at the same entry where possible.
            let currentPath = state.index >= 0 && state.index < state.history.count
                ? state.history[state.index] : nil
            state.history = surviving
            state.index = currentPath.flatMap { surviving.firstIndex(of: $0) } ?? surviving.count - 1
        }
        if let current = state.current, !fm.fileExists(atPath: current) {
            state.current = nil
        }
        return state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
