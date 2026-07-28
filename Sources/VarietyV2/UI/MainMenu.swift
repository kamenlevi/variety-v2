import AppKit

/// The application menu bar.
///
/// A menu bar app started life as `LSUIElement`, which ships with *no* main
/// menu at all. That is not merely cosmetic: without an Edit menu there are no
/// Cut/Copy/Paste key equivalents, so ⌘V does nothing in any text field in any
/// window the app opens — which makes pasting an API key into Preferences
/// impossible. The standard responder actions have to be present as menu items
/// for their shortcuts to reach the first responder.
///
/// Building it by hand rather than from a nib, since this target has no
/// Interface Builder resources.
enum MainMenu {

    static func install() {
        let main = NSMenu()

        main.addItem(applicationMenuItem())
        main.addItem(editMenuItem())
        main.addItem(windowMenuItem())

        NSApp.mainMenu = main
    }

    // MARK: - Application

    private static func applicationMenuItem() -> NSMenuItem {
        let name = "Variety"
        let item = NSMenuItem()
        let menu = NSMenu(title: name)

        menu.addItem(withTitle: "About \(name)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let settings = menu.addItem(withTitle: "Settings…",
                                    action: #selector(AppDelegate.openPreferencesFromMenu),
                                    keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]

        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(name)",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(name)",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: - Edit

    /// The reason this file exists. These are the standard responder actions;
    /// AppKit routes them to whatever text field is focused.
    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    // MARK: - Window

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
