import AppKit
import SwiftUI

/// Menu bar app.
///
/// The menu mirrors Variety's indicator menu item for item — Next, Previous,
/// the current filename, View at source, Favorites, Delete to Trash, an Image
/// submenu, History, Wallpaper Selector, Start Slideshow, Preferences, About,
/// Quit — because that menu *is* the app's interface on both platforms.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var rotator: Rotator!
    private var preferencesWindow: NSWindow?
    private var filmstrip: FilmstripPanel?
    private var searchWindow: NSWindow?
    private var slideshow: SlideshowController?
    private var menuTargets: [ClosureMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings.load()
        rotator = Rotator(settings: settings)
        rotator.onChange = { [weak self] in self?.rebuildMenu() }

        try? settings.save()

        if settings.startAtLogin != LoginItem.isEnabled {
            LoginItem.set(settings.startAtLogin)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                   accessibilityDescription: "Variety")
            button.image?.isTemplate = true
        }

        // Without a main menu there is no Edit menu, and therefore no working
        // Cut/Copy/Paste in any text field the app shows.
        MainMenu.install()

        rebuildMenu()
        rotator.start()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menuTargets = []

        add(menu, "Next", key: "n") { [weak self] in Task { await self?.rotator.next() } }
        add(menu, "Previous", key: "p") { [weak self] in Task { await self?.rotator.previous() } }

        menu.addItem(.separator())

        if let current = rotator.current {
            let name = NSMenuItem(title: current.lastPathComponent, action: nil, keyEquivalent: "")
            name.isEnabled = false
            menu.addItem(name)

            if let origin = rotator.currentOrigin, origin.originURL != nil {
                add(menu, "View at \(origin.sourceName)", key: "") { [weak self] in
                    self?.rotator.openCurrentOrigin()
                }
            }

            let isFavorite = rotator.currentIsFavorite
            add(menu, isFavorite ? "Already in Favorites" : "Move to Favorites",
                key: "f", enabled: !isFavorite) { [weak self] in
                self?.rotator.favoriteCurrent()
            }
            add(menu, "Delete to Trash", key: "d") { [weak self] in
                Task { await self?.rotator.trashCurrent() }
            }

            menu.addItem(.separator())
            menu.addItem(imageSubmenuItem())
        }

        menu.addItem(.separator())

        add(menu, "Find Images…", key: "k") { [weak self] in self?.showSearch() }
        add(menu, "History", key: "h") { [weak self] in self?.showFilmstrip(.history) }
        add(menu, "Wallpaper Selector", key: "l") { [weak self] in self?.showFilmstrip(.selector) }
        add(menu, "Recent Downloads", key: "j") { [weak self] in self?.showFilmstrip(.downloads) }

        menu.addItem(.separator())

        let running = slideshow?.isRunning ?? false
        add(menu, running ? "Stop Slideshow" : "Start Slideshow", key: "s") { [weak self] in
            self?.toggleSlideshow()
        }

        let paused = rotator.isPaused
        add(menu, paused ? "Resume Rotation" : "Pause Rotation", key: "r") { [weak self] in
            guard let self else { return }
            self.rotator.setPaused(!self.rotator.isPaused)
            self.rebuildMenu()
        }

        menu.addItem(.separator())
        add(menu, "Preferences…", key: ",") { [weak self] in self?.showPreferences() }
        add(menu, "About Variety", key: "") { [weak self] in self?.showPreferences(tab: "About") }
        add(menu, "Donate", key: "") {
            NSWorkspace.shared.open(DonateTab.payPalURL)
        }
        add(menu, "Quit Variety", key: "q") { NSApp.terminate(nil) }

        statusItem.menu = menu
    }

    /// Variety's "Image ▸" submenu of per-image actions.
    private func imageSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Image", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        add(submenu, "Show in Finder", key: "") { [weak self] in self?.rotator.revealCurrent() }
        add(submenu, "Open in Preview", key: "") { [weak self] in
            guard let current = self?.rotator.current else { return }
            NSWorkspace.shared.open(current)
        }
        add(submenu, "Copy to Folder…", key: "") { [weak self] in self?.copyCurrent() }
        add(submenu, "Copy Path", key: "") { [weak self] in
            guard let current = self?.rotator.current else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(current.path, forType: .string)
        }

        item.submenu = submenu
        return item
    }

    private func add(_ menu: NSMenu, _ title: String, key: String,
                     enabled: Bool = true, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuItem.invoke), keyEquivalent: key)
        let target = ClosureMenuItem(action: action)
        item.target = target
        item.isEnabled = enabled
        // Retained by the delegate: NSMenuItem holds its target weakly.
        menuTargets.append(target)
        menu.addItem(item)
    }

    // MARK: - Windows

    @objc func openPreferencesFromMenu() { showPreferences() }

    private func showPreferences(tab: String? = nil) {
        if let preferencesWindow {
            WindowPresenter.shared.present(preferencesWindow)
            return
        }

        let view = PreferencesView(settings: rotator.settings, rotator: rotator) { [weak self] updated in
            guard let self else { return }
            self.rotator.applySettings(updated)
            Task { await self.rotator.redrawCurrent() }
        }

        let window = WindowPresenter.shared.makeWindow(
            title: "Variety Preferences",
            size: NSSize(width: 780, height: 600),
            minSize: NSSize(width: 700, height: 480))
        window.contentView = NSHostingView(rootView: view)
        WindowPresenter.shared.present(window)
        preferencesWindow = window
    }

    private func showFilmstrip(_ contents: FilmstripPanel.Contents) {
        let panel = filmstrip ?? FilmstripPanel(rotator: rotator)
        filmstrip = panel
        if panel.isVisible, panel.contents == contents {
            panel.orderOut(nil)
            return
        }
        panel.contents = contents
        panel.reload()
        panel.present()
    }

    /// Search a service by subject and add it to the rotation.
    private func showSearch() {
        if let searchWindow {
            WindowPresenter.shared.present(searchWindow)
            return
        }
        let view = ImageSearchView(settings: rotator.settings) { [weak self] source in
            guard let self else { return }
            var updated = self.rotator.settings
            if !updated.sources.contains(where: { $0.id == source.id }) {
                updated.sources.append(source)
            }
            self.rotator.applySettings(updated)
            Task { await self.rotator.refillIfNeeded(minimum: .max) }
            self.searchWindow?.close()
            self.searchWindow = nil
        }

        let window = WindowPresenter.shared.makeWindow(
            title: "Find Images", size: NSSize(width: 820, height: 620))
        window.contentView = NSHostingView(rootView: view)
        WindowPresenter.shared.present(window)
        searchWindow = window
    }


    private func toggleSlideshow() {
        if let slideshow, slideshow.isRunning {
            slideshow.stop()
            self.slideshow = nil
        } else {
            let controller = SlideshowController(rotator: rotator)
            controller.onStop = { [weak self] in
                self?.slideshow = nil
                self?.rebuildMenu()
            }
            controller.onNeedsPreferences = { [weak self] in self?.showPreferences() }
            controller.start()
            slideshow = controller
        }
        rebuildMenu()
    }

    private func copyCurrent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Copy Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rotator.copyCurrent(to: url)
    }
}

/// Carries a closure for an `NSMenuItem` target/action pair.
final class ClosureMenuItem: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
