import AppKit
import SwiftUI

/// Menu bar app. There is no Dock icon and no main window — `LSUIElement` is
/// set in the bundle's Info.plist — so the status item is the whole surface,
/// standing in for Variety's AppIndicator tray menu, which has no macOS
/// equivalent.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var rotator: Rotator!
    private var settingsWindow: NSWindow?
    private var thumbnails: ThumbnailPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings.load()
        rotator = Rotator(settings: settings)
        rotator.onChange = { [weak self] in self?.rebuildMenu() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                   accessibilityDescription: "Variety")
            button.image?.isTemplate = true
        }

        rebuildMenu()
        rotator.start()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        if let origin = rotator.currentOrigin {
            let title = origin.title?.prefix(60) ?? Substring(origin.sourceName)
            let item = NSMenuItem(title: String(title), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

            if let author = origin.author {
                let byline = NSMenuItem(title: "by \(author)", action: nil, keyEquivalent: "")
                byline.isEnabled = false
                menu.addItem(byline)
            }
            menu.addItem(.separator())
        }

        add(to: menu, "Next Wallpaper", key: "n") { [weak self] in
            Task { await self?.rotator.next() }
        }
        add(to: menu, "Previous Wallpaper", key: "p") { [weak self] in
            Task { await self?.rotator.previous() }
        }

        menu.addItem(.separator())

        let isFavorite = rotator.currentIsFavorite
        add(to: menu, isFavorite ? "In Favorites ✓" : "Add to Favorites", key: "f",
            enabled: !isFavorite && rotator.current != nil) { [weak self] in
            self?.rotator.favoriteCurrent()
        }
        add(to: menu, "Move to Trash", key: "d", enabled: rotator.current != nil) { [weak self] in
            Task { await self?.rotator.trashCurrent() }
        }
        add(to: menu, "Show in Finder", key: "", enabled: rotator.current != nil) { [weak self] in
            self?.rotator.revealCurrent()
        }
        add(to: menu, "View Source Page", key: "",
            enabled: rotator.currentOrigin?.originURL != nil) { [weak self] in
            self?.rotator.openCurrentOrigin()
        }

        menu.addItem(.separator())

        add(to: menu, "Recent Wallpapers…", key: "t") { [weak self] in
            self?.toggleThumbnails()
        }

        let pauseTitle = rotator.isPaused ? "Resume Rotation" : "Pause Rotation"
        add(to: menu, pauseTitle, key: "s") { [weak self] in
            guard let self else { return }
            self.rotator.setPaused(!self.rotator.isPaused)
            self.rebuildMenu()
        }

        menu.addItem(.separator())
        add(to: menu, "Settings…", key: ",") { [weak self] in self?.showSettings() }
        add(to: menu, "Quit Variety", key: "q") { NSApp.terminate(nil) }

        statusItem.menu = menu
    }

    /// Small wrapper so menu items can carry closures instead of requiring a
    /// selector per action.
    private func add(to menu: NSMenu, _ title: String, key: String,
                     enabled: Bool = true, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuItem.invoke), keyEquivalent: key)
        let target = ClosureMenuItem(action: action)
        item.target = target
        item.representedObject = target   // keep the target alive
        item.isEnabled = enabled
        menu.addItem(item)
    }

    // MARK: - Windows

    private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(settings: rotator.settings) { [weak self] updated in
            self?.rotator.applySettings(updated)
            Task { await self?.rotator.redrawCurrent() }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Variety Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    private func toggleThumbnails() {
        if let thumbnails, thumbnails.isVisible {
            thumbnails.orderOut(nil)
            return
        }
        let panel = thumbnails ?? ThumbnailPanel(rotator: rotator)
        thumbnails = panel
        panel.reload()
        panel.present()
    }
}

/// Carries a closure for an `NSMenuItem` target/action pair.
final class ClosureMenuItem: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
