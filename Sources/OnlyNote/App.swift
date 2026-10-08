import AppKit
import Combine
import NoteCore
import ServiceManagement
import SwiftUI

// Only Note: a note icon in the menu bar. A click (or ⌥⌘N anywhere) opens the note under it;
// clicking elsewhere puts it away, unless it's pinned. Right-click the icon for its menu.

@main
enum OnlyNoteMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = NoteModel()
    let updater = Updater()
    private var statusItem: NSStatusItem!
    private var panel: NotePanel!
    private let hotKey = HotKey()
    private var outsideWatch: Timer?
    private var watches: [AnyCancellable] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        makePanel()
        makeStatusItem()
        updater.start()
        model.onSettingsChange = { [weak self] old in self?.settingsChanged(from: old) }
        model.onPluginsChange = { [weak self] in self?.buildMainMenu() }
        if model.settings.hotKey { hotKey.register { [weak self] in self?.toggle() } }
        // The menu bar icon wears a dot while there's an update.
        updater.$state.sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }.store(in: &watches)
        // The window's top strip wears the note's colors.
        model.$settings.combineLatest(model.$appearanceTick).sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyPanelColors() }
        }.store(in: &watches)
        // Open at login from the first launch (the settings have a switch).
        let key = "didSetUpOpenAtLogin"
        if !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleURL.pathExtension == "app" {
            UserDefaults.standard.set(true, forKey: key)
            try? SMAppService.mainApp.register()
        }
        // The first time, show the note so it's clear where it lives.
        if !UserDefaults.standard.bool(forKey: "didShowOnce") {
            UserDefaults.standard.set(true, forKey: "didShowOnce")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flush()
    }

    func applicationDidResignActive(_ notification: Notification) {
        model.flush()
    }

    // MARK: The menu bar icon

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Only Note (⌥⌘N)"
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        // With a + while there's an update.
        let name = updater.hasUpdate ? "note.text.badge.plus" : "note.text"
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: "Only Note")
            ?? NSImage(systemSymbolName: "note.text", accessibilityDescription: "Only Note"))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        button.image = image
        button.toolTip = updater.hasUpdate ? "Only Note: an update is ready (right-click)" : "Only Note (⌥⌘N)"
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            toggle()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: panel.isVisible ? "Hide the note" : "Show the note", action: #selector(toggleFromMenu(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        switch updater.state {
        case .available(let u):
            menu.addItem(withTitle: "Update to \(u.commit.short)…", action: #selector(installUpdate(_:)), keyEquivalent: "").target = self
        case .installing(let step):
            menu.addItem(withTitle: step, action: nil, keyEquivalent: "")
        default:
            menu.addItem(withTitle: "Check for updates", action: #selector(checkForUpdates(_:)), keyEquivalent: "").target = self
        }
        let version = menu.addItem(withTitle: "Version \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Show the note's file", action: #selector(revealNote(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Only Note", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleFromMenu(_ sender: Any?) { toggle() }
    @objc private func installUpdate(_ sender: Any?) { model.flush(); updater.install() }
    @objc private func checkForUpdates(_ sender: Any?) { updater.check(userInitiated: true); show(); model.overlay = .settings }
    @objc private func revealNote(_ sender: Any?) { model.revealInFinder() }
    @objc private func toggleOpenAtLogin(_ sender: Any?) {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
    }

    // MARK: The panel

    private func makePanel() {
        let s = model.settings
        panel = NotePanel(contentRect: NSRect(x: 0, y: 0, width: s.width, height: s.height))
        panel.delegate = self
        panel.minSize = NSSize(width: NoteSettings.minSize.width, height: NoteSettings.minSize.height)
        let host = NSHostingView(rootView: NoteView(model: model, updater: updater))
        host.sizingOptions = []
        panel.contentView = host
        applyPanelLevel()
    }

    func toggle() {
        if panel.isVisible, panel.isKeyWindow { hide() } else { show() }
    }

    func show() {
        if !model.settings.pinned || !panel.isVisible { position() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let tv = model.editor { panel.makeFirstResponder(tv) }
        model.checkForOutsideChanges()
        startWatchingOutside()
    }

    func hide() {
        model.flush()
        model.overlay = nil
        panel.orderOut(nil)
        outsideWatch?.invalidate()
        outsideWatch = nil
    }

    /// Esc: closes an overlay first, else puts the note away.
    @objc func escape(_ sender: Any?) {
        if model.overlay != nil { model.overlay = nil } else { hide() }
    }

    /// Under the menu bar icon, its top centred on it (kept on the screen).
    private func position() {
        guard let button = statusItem?.button, let window = button.window else {
            panel.center()
            return
        }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var frame = panel.frame
        frame.origin.x = min(max(icon.midX - frame.width / 2, screen.minX + 8), screen.maxX - frame.width - 8)
        frame.origin.y = icon.minY - 6 - frame.height
        if frame.minY < screen.minY + 8 {
            frame.size.height = max(panel.minSize.height, icon.minY - 6 - screen.minY - 8)
            frame.origin.y = icon.minY - 6 - frame.height
        }
        panel.setFrame(frame, display: false)
    }

    private func applyPanelLevel() {
        // Above other apps' windows: pinned, it stays there while you work in them.
        panel.level = .floating
        panel.hidesOnDeactivate = false
    }

    private func applyPanelColors() {
        let theme = model.theme
        panel.backgroundColor = theme.background
        panel.appearance = theme.appearance
    }

    private func startWatchingOutside() {
        guard outsideWatch == nil else { return }
        outsideWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.checkForOutsideChanges() }
        }
    }

    private func settingsChanged(from old: NoteSettings) {
        let s = model.settings
        if s.pinned != old.pinned { applyPanelLevel() }
        if s.hotKey != old.hotKey {
            if s.hotKey { hotKey.register { [weak self] in self?.toggle() } } else { hotKey.unregister() }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking away puts it away, unless it's pinned (or a menu or the find bar took the keys).
        guard !model.settings.pinned else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow, NSApp.modalWindow == nil else { return }
            if let key = NSApp.keyWindow, key.parent === self.panel || key is NSPanel && key !== self.panel { return }
            self.hide()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        let size = panel.contentRect(forFrameRect: panel.frame).size
        model.settings.width = size.width
        model.settings.height = size.height
    }

    // MARK: The menus (their keys work while the note is up)

    func buildMainMenu() {
        let main = NSMenu()

        let app = NSMenu(title: "Only Note")
        app.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(withTitle: "History", action: #selector(openHistory(_:)), keyEquivalent: "y").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide the Note", action: #selector(hideFromMenu(_:)), keyEquivalent: "w").target = self
        app.addItem(withTitle: "Quit Only Note", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        for (title, key, mods, action) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find and Replace…", "f", [.command, .option], .showReplaceInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", .command, .setSearchString),
        ] as [(String, String, NSEvent.ModifierFlags, NSTextFinder.Action)] {
            let item = find.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = action.rawValue
        }
        let findItem = edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        edit.setSubmenu(find, for: findItem)
        let spelling = edit.addItem(withTitle: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        spelling.keyEquivalentModifierMask = .command
        add(edit, to: main)

        let format = NSMenu(title: "Format")
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) {
            let i = format.addItem(withTitle: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
        }
        item("Tick Task / Make Checklist", #selector(NoteTextView.toggleTasks(_:)), "\r")
        item("Bold", #selector(NoteTextView.makeBold(_:)), "b")
        item("Italic", #selector(NoteTextView.makeItalic(_:)), "i")
        item("Code", #selector(NoteTextView.makeCode(_:)), "k")
        item("Strikethrough", #selector(NoteTextView.makeStruck(_:)), "x", [.command, .shift])
        item("Highlight", #selector(NoteTextView.makeMarked(_:)), "h", [.command, .shift])
        format.addItem(.separator())
        item("Heading 1", #selector(NoteTextView.makeHeading(_:)), "1", tag: 1)
        item("Heading 2", #selector(NoteTextView.makeHeading(_:)), "2", tag: 2)
        item("Heading 3", #selector(NoteTextView.makeHeading(_:)), "3", tag: 3)
        item("Plain Text", #selector(NoteTextView.makeHeading(_:)), "0", [.command, .option], tag: 0)
        format.addItem(.separator())
        item("Indent", #selector(NoteTextView.indentLines(_:)), "]")
        item("Outdent", #selector(NoteTextView.outdentLines(_:)), "[")
        format.addItem(.separator())
        let bigger = format.addItem(withTitle: "Bigger", action: #selector(bigger(_:)), keyEquivalent: "+")
        bigger.target = self
        let bigger2 = format.addItem(withTitle: "Bigger", action: #selector(bigger(_:)), keyEquivalent: "=")
        bigger2.target = self
        bigger2.isHidden = true
        bigger2.allowsKeyEquivalentWhenHidden = true
        format.addItem(withTitle: "Smaller", action: #selector(smaller(_:)), keyEquivalent: "-").target = self
        format.addItem(withTitle: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "0").target = self
        add(format, to: main)

        let plugins = NSMenu(title: "Plugins")
        for plugin in model.commands {
            let i = plugins.addItem(withTitle: plugin.name, action: #selector(runPlugin(_:)), keyEquivalent: plugin.key ?? "")
            i.keyEquivalentModifierMask = [.control, .option]
            i.representedObject = plugin.id
            i.target = self
            i.image = NSImage(systemSymbolName: plugin.symbol, accessibilityDescription: nil)
        }
        if !model.commands.isEmpty { plugins.addItem(.separator()) }
        plugins.addItem(withTitle: "Manage Plugins…", action: #selector(openPlugins(_:)), keyEquivalent: "").target = self
        plugins.addItem(withTitle: "Reload Plugins", action: #selector(reloadPlugins(_:)), keyEquivalent: "").target = self
        add(plugins, to: main)

        NSApp.mainMenu = main
    }

    private func add(_ menu: NSMenu, to main: NSMenu) {
        let item = main.addItem(withTitle: menu.title, action: nil, keyEquivalent: "")
        main.setSubmenu(menu, for: item)
    }

    @objc private func openSettings(_ sender: Any?) { show(); model.overlay = .settings }
    @objc private func openHistory(_ sender: Any?) { show(); model.overlay = .history }
    @objc private func openPlugins(_ sender: Any?) { show(); model.overlay = .plugins }
    @objc private func hideFromMenu(_ sender: Any?) { hide() }
    @objc private func reloadPlugins(_ sender: Any?) { model.reloadPlugins() }
    @objc private func bigger(_ sender: Any?) { model.biggerText() }
    @objc private func smaller(_ sender: Any?) { model.smallerText() }
    @objc private func actualSize(_ sender: Any?) { model.resetText() }
    @objc private func runPlugin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let plugin = model.plugins.first(where: { $0.id == id }) else { return }
        model.run(plugin)
    }
}

/// The note's window: rounded, resizable from its edges, and able to take the keyboard though the
/// app has no Dock icon. Its title bar is a slim strip in the note's color, with no title or
/// buttons: something to drag it by, when it's pinned.
final class NotePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.titled, .resizable, .closable],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// ⌘W (and the red button, if it ever shows) hides it rather than closing it for good.
    override func performClose(_ sender: Any?) {
        orderOut(sender)
    }
}
