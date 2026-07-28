import AppKit

/// Keeps the app's activation policy in step with whether it has windows open.
///
/// A menu bar app runs as `.accessory`: no Dock icon, and — the part that
/// matters here — it does not appear in the Cmd-Tab switcher and its windows
/// get no proper application presence. That is right when only the status item
/// is showing, and wrong the moment a real window like Preferences is open,
/// because the window then cannot be switched back to once it is behind
/// something else.
///
/// So the policy is promoted to `.regular` while any window is open and
/// demoted again when the last one closes.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {

    static let shared = WindowPresenter()

    private var open: Set<ObjectIdentifier> = []

    /// Shows a window, adopting it into the tracked set.
    func present(_ window: NSWindow, activate: Bool = true) {
        window.delegate = self
        // Windows are kept alive by the owner; closing must not deallocate them
        // out from under a stored reference.
        window.isReleasedWhenClosed = false

        if open.insert(ObjectIdentifier(window)).inserted {
            updatePolicy()
        }

        window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate(ignoringOtherApps: true) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        open.remove(ObjectIdentifier(window))
        // The policy change has to wait until the window has actually gone, or
        // AppKit reinstates a Dock icon for the closing window.
        DispatchQueue.main.async { [weak self] in self?.updatePolicy() }
    }

    private func updatePolicy() {
        let wanted: NSApplication.ActivationPolicy = open.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)

        if wanted == .regular {
            // Promoting while already frontmost does not always give key focus.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Builds a standard application window: titled, closable, minimisable and
    /// resizable, so it behaves like any other Mac window.
    func makeWindow(title: String, size: NSSize, minSize: NSSize? = nil) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.setContentSize(size)
        window.minSize = minSize ?? NSSize(width: size.width * 0.75, height: size.height * 0.6)
        window.center()
        window.isReleasedWhenClosed = false
        // Remember position and size between launches.
        window.setFrameAutosaveName("VarietyV2.\(title)")
        return window
    }
}
