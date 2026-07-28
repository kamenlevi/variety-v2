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
    private var selectorWindow: NSWindow?
    private var slideshow: SlideshowController?
    private var menuTargets: [ClosureMenuItem] = []
    private var appearanceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings.load()
        rotator = Rotator(settings: settings)
        rotator.onChange = { [weak self] in self?.rebuildMenu() }

        try? settings.save()

        if settings.startAtLogin != LoginItem.isEnabled {
            LoginItem.set(settings.startAtLogin)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.statusIcon(preference: settings.icon)

        // Re-tint when the system flips between light and dark.
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statusItem.button?.image = Self.statusIcon(preference: self.rotator.settings.icon)
            }
        }

        // Without a main menu there is no Edit menu, and therefore no working
        // Cut/Copy/Paste in any text field the app shows.
        MainMenu.install()

        rebuildMenu()
        rotator.start()
    }

    /// Variety's *indicator* icon, at menu bar size.
    ///
    /// Not the application icon: Variety uses a separate tray glyph
    /// (`variety-indicator`), and ships two tints of it — the light one for
    /// dark panels and `variety-indicator-dark` for light ones, chosen by the
    /// `icon` option. That choice is made here from the menu bar's actual
    /// appearance when the setting is left on Auto.
    ///
    /// Deliberately *not* a template image. A template uses only the alpha
    /// channel, and this artwork's alpha is the whole monitor silhouette, so
    /// it would render as a featureless slab.
    private static func statusIcon(preference: String) -> NSImage {
        let height: CGFloat = 18
        let name: String

        switch preference {
        case "Light": name = "variety-indicator"
        case "Dark":  name = "variety-indicator-dark"
        default:
            // Auto: the light glyph reads against a dark menu bar, and vice versa.
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            name = dark ? "variety-indicator" : "variety-indicator-dark"
        }

        if let url = Bundle.main.url(forResource: name, withExtension: "svg"),
           let source = NSImage(contentsOf: url) {
            let aspect = source.size.height > 0 ? source.size.width / source.size.height : 1
            let size = NSSize(width: height * aspect, height: height)

            let image = NSImage(size: size, flipped: false) { rect in
                source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            image.isTemplate = false
            return image
        }

        // Running from the bare binary during development, where there is no
        // bundle to read resources from.
        let fallback = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                               accessibilityDescription: "Variety")!
        fallback.isTemplate = true
        return fallback
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menuTargets = []

        add(menu, "Next", key: "n") { [weak self] in Task { await self?.rotator.next() } }
        add(menu, "Previous", key: "p") { [weak self] in Task { await self?.rotator.previous() } }

        menu.addItem(.separator())

        // The per-image section is always present, disabled when there is
        // nothing to act on. Hiding it entirely — which is what happened when
        // no wallpaper had been set yet this session — made the menu appear to
        // lose features at random.
        let current = rotator.current
        let name = NSMenuItem(title: current?.lastPathComponent ?? "No wallpaper set yet",
                              action: nil, keyEquivalent: "")
        name.isEnabled = false
        menu.addItem(name)

        if let origin = rotator.currentOrigin, origin.originURL != nil {
            add(menu, "View at \(origin.sourceName)", key: "") { [weak self] in
                self?.rotator.openCurrentOrigin()
            }
        }

        let isFavorite = rotator.currentIsFavorite
        add(menu, isFavorite ? "Already in Favorites" : "Move to Favorites",
            key: "f", enabled: current != nil && !isFavorite) { [weak self] in
            self?.rotator.favoriteCurrent()
        }
        add(menu, "Delete to Trash", key: "d", enabled: current != nil) { [weak self] in
            Task { await self?.rotator.trashCurrent() }
        }

        menu.addItem(.separator())
        menu.addItem(imageSubmenuItem(enabled: current != nil))

        menu.addItem(.separator())

        add(menu, "Find Images…", key: "k") { [weak self] in self?.showSearch() }
        menu.addItem(historyMenuItem())
        add(menu, "Wallpaper Selector…", key: "l") { [weak self] in self?.showSelector() }
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

    /// History as an actual list you can jump around in.
    ///
    /// It used to be a single item that opened the filmstrip — which was empty
    /// after every relaunch, since history lived only in memory. Now the state
    /// persists, and the recent entries are right here with their thumbnails,
    /// so going back two wallpapers takes one click rather than opening a strip
    /// and hunting.
    private func historyMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let entries = rotator.historyForDisplay
        if entries.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for file in entries.prefix(15) {
                let entry = NSMenuItem(title: Self.menuTitle(for: file),
                                       action: #selector(ClosureMenuItem.invoke),
                                       keyEquivalent: "")
                let target = ClosureMenuItem { [weak self] in
                    Task { await self?.rotator.show(file: file) }
                }
                entry.target = target
                entry.image = Self.menuThumbnail(for: file)
                entry.state = (file == rotator.current) ? .on : .off
                menuTargets.append(target)
                submenu.addItem(entry)
            }

            submenu.addItem(.separator())
            let strip = NSMenuItem(title: "Show as Filmstrip…",
                                   action: #selector(ClosureMenuItem.invoke), keyEquivalent: "")
            let target = ClosureMenuItem { [weak self] in self?.showFilmstrip(.history) }
            strip.target = target
            menuTargets.append(target)
            submenu.addItem(strip)
        }

        item.submenu = submenu
        return item
    }

    /// A short, readable name — download filenames are long and id-shaped.
    private static func menuTitle(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        return stem.count > 45 ? String(stem.prefix(42)) + "…" : stem
    }

    private static func menuThumbnail(for file: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
              ] as CFDictionary)
        else { return nil }

        let image = NSImage(cgImage: cg, size: .zero)
        let height: CGFloat = 24
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1.6
        image.size = NSSize(width: height * aspect, height: height)
        return image
    }

    /// Variety's "Image ▸" submenu of per-image actions.
    private func imageSubmenuItem(enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: "Image", action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        let submenu = NSMenu()

        add(submenu, "Show in Finder", key: "") { [weak self] in self?.rotator.revealCurrent() }
        add(submenu, "Open in Preview", key: "") { [weak self] in
            guard let current = self?.rotator.current else { return }
            NSWorkspace.shared.open(current)
        }
        add(submenu, "More Like This…", key: "m") { [weak self] in self?.showMoreLikeThis() }
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
            self.statusItem.button?.image = Self.statusIcon(preference: updated.icon)
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

    /// The browsable grid of everything the enabled sources offer.
    private func showSelector() {
        if let selectorWindow {
            WindowPresenter.shared.present(selectorWindow)
            return
        }
        let window = WindowPresenter.shared.makeWindow(
            title: "Wallpaper Selector",
            // Sized for browsing: the old window was too small to judge more
            // than a handful of wallpapers at a time.
            size: NSSize(width: 1180, height: 780),
            minSize: NSSize(width: 700, height: 480))
        window.contentView = NSHostingView(rootView: WallpaperSelectorView(rotator: rotator))
        WindowPresenter.shared.present(window)
        selectorWindow = window
    }

    /// Derives a query from the current wallpaper's own tags and searches it.
    private func showMoreLikeThis() {
        guard let origin = rotator.currentOrigin else { return }

        Task { @MainActor in
            guard let suggestion = await SimilarImages.suggestion(for: origin) else {
                let alert = NSAlert()
                alert.messageText = "Nothing to go on"
                alert.informativeText = """
                    This wallpaper carries no tags or description to build a                     search from. It works best on images from Wallhaven and                     Unsplash, which tag their photos.
                    """
                alert.runModal()
                return
            }

            let service: ImageSearchView.Service =
                suggestion.kind == .unsplash ? .unsplash : .wallhaven
            let because = "Matching “\(suggestion.terms.joined(separator: ", "))” "
                + "from the current wallpaper"

            self.showSearch(initial: (service, suggestion.query, because))
        }
    }

    /// Search a service by subject and add it to the rotation.
    private func showSearch(initial: (ImageSearchView.Service, String, String)? = nil) {
        // A pre-filled search replaces any open one, or it would silently do
        // nothing when the window is already up.
        if let searchWindow, initial == nil {
            WindowPresenter.shared.present(searchWindow)
            return
        }
        if initial != nil, let existing = searchWindow {
            existing.close()
            searchWindow = nil
        }

        let view = ImageSearchView(settings: rotator.settings, onAdd: { [weak self] source in
            guard let self else { return }
            var updated = self.rotator.settings
            if !updated.sources.contains(where: { $0.id == source.id }) {
                updated.sources.append(source)
            }
            self.rotator.applySettings(updated)
            Task { await self.rotator.refillIfNeeded(minimum: .max) }
            self.searchWindow?.close()
            self.searchWindow = nil
        }, initial: initial.map { (service: $0.0, query: $0.1, because: $0.2) })

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
