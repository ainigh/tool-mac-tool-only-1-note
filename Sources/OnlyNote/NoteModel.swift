import AppKit
import Combine
import NoteCore
import SwiftUI

/// The one note: its text (saved a moment after each change, and when the app goes away), its
/// history, the settings, the plugins, and what the footer says.
@MainActor
final class NoteModel: ObservableObject {
    enum SaveState: Equatable {
        case saved
        case unsaved
        case failed(String)
    }

    /// What covers the note for a moment (each from a footer button).
    enum Overlay: Equatable {
        case history, plugins, settings
    }

    let vault: NoteVault
    private let settingsURL: URL

    /// The text as last typed (the text view holds the real one).
    private(set) var text: String
    @Published private(set) var saveState: SaveState = .saved
    @Published private(set) var statuses: [String] = []
    /// A word from a plugin (or a problem), for a few seconds, in place of the statuses.
    @Published private(set) var flash: String?
    @Published var overlay: Overlay?
    @Published private(set) var plugins: [NotePlugin] = []
    @Published private(set) var runningPlugin: String?
    @Published var settings: NoteSettings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            applyLook()
            if settings.plugins != oldValue.plugins { refreshStatuses(); onPluginsChange?() }
            onSettingsChange?(oldValue)
        }
    }
    /// The Mac's light or dark changed (for "Match the Mac").
    @Published private(set) var appearanceTick = 0

    weak var editor: NoteTextView?
    var onSettingsChange: ((NoteSettings) -> Void)?
    var onPluginsChange: (() -> Void)?

    private var saveTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    /// When the app last wrote the note (a later date on the file means something else did).
    private var lastWrite: Date?
    private var revision = 0
    private var appearanceObserver: NSKeyValueObservation?

    init(vault: NoteVault = NoteVault(folder: NoteVault.standardFolder)) {
        self.vault = vault
        settingsURL = vault.folder.appendingPathComponent("settings.json")
        settings = NoteSettings.load(from: settingsURL)
        text = vault.load(welcome: Welcome.text)
        lastWrite = vault.modificationDate()
        ScriptPlugins.prepare(vault.pluginsFolder)
        reloadPlugins(quietly: true)
        refreshStatuses()
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.settings.theme == .auto else { return }
                self.appearanceTick += 1
                self.applyLook()
            }
        }
    }

    var theme: Theme { Theme.resolve(settings.theme) }
    var typography: Typography { Typography(typeface: settings.typeface, size: settings.fontSize) }

    // MARK: The editor

    func attach(_ tv: NoteTextView) {
        editor = tv
        tv.onChange = { [weak self] new in self?.textChanged(new) }
        tv.onSelectionChange = { range in
            UserDefaults.standard.set(range.location, forKey: "caret")
        }
        applyLook()
        tv.isContinuousSpellCheckingEnabled = settings.spellCheck
        tv.setText(text, undoable: false, caret: UserDefaults.standard.integer(forKey: "caret"))
    }

    func applyLook() {
        guard let tv = editor else { return }
        tv.apply(theme: theme, typography: typography, lineSpacing: settings.lineSpacing, readableWidth: settings.readableWidth)
        if tv.isContinuousSpellCheckingEnabled != settings.spellCheck { tv.isContinuousSpellCheckingEnabled = settings.spellCheck }
    }

    private func textChanged(_ new: String) {
        guard new != text else { return }
        text = new
        revision += 1
        saveState = .unsaved
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshStatuses()
        }
    }

    // MARK: Saving

    func save() {
        saveTask?.cancel()
        guard saveState != .saved else { return }
        do {
            try vault.save(text)
            lastWrite = vault.modificationDate()
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    /// Saves now if there's anything to save (before quitting, updating, or hiding).
    func flush() {
        if saveState != .saved { save() }
    }

    /// Picks up a change made to the file by something else (another editor, a sync), keeping
    /// a copy of both in the history. While there are unsaved changes here, those win.
    func checkForOutsideChanges() {
        guard let date = vault.modificationDate(), let last = lastWrite, date > last.addingTimeInterval(0.5) else { return }
        let theirs = vault.load()
        lastWrite = date
        guard theirs != text else { return }
        if saveState != .saved {
            try? vault.snapshot(theirs, force: true)
            save()
            show("The note changed on disk too: that version is in the history")
            return
        }
        try? vault.snapshot(text, force: true)
        text = theirs
        editor?.setText(theirs, undoable: true)
        // The edit above is ours to undo, but the file already holds it.
        saveTask?.cancel()
        saveState = .saved
        refreshStatuses()
        show("Updated from the file on disk")
    }

    // MARK: History

    func restore(_ snapshot: NoteVault.Snapshot) {
        guard let old = try? vault.read(snapshot) else { return show("Couldn't read that version") }
        try? vault.snapshot(text, force: true)
        editor?.setText(old, undoable: true)
        overlay = nil
        show("Restored the version from \(Self.when(snapshot.date)) (⌘Z undoes it)")
    }

    static func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: Plugins

    var commands: [NotePlugin] { plugins.filter { $0.command != nil && settings.isOn($0) } }

    func reloadPlugins(quietly: Bool = false) {
        let scripts = ScriptPlugins.load(from: vault.pluginsFolder, noteFile: vault.noteURL)
        plugins = BuiltInPlugins.all + scripts
        refreshStatuses()
        onPluginsChange?()
        if !quietly { show(scripts.count == 1 ? "1 script plugin" : "\(scripts.count) script plugins") }
    }

    func setPlugin(_ plugin: NotePlugin, on: Bool) {
        settings.plugins[plugin.id] = on
    }

    func run(_ plugin: NotePlugin) {
        guard let command = plugin.command, let tv = editor, runningPlugin == nil else { return }
        overlay = nil
        let ctx = PluginContext(text: tv.string, selection: tv.selectedRange())
        let started = revision
        runningPlugin = plugin.name
        // A script can take a while: off the main thread, then applied only if the note's the same.
        Task.detached(priority: .userInitiated) {
            let result: Result<PluginResult, Error> = Result { try command(ctx) }
            await MainActor.run {
                self.runningPlugin = nil
                switch result {
                case .failure(let error):
                    self.show(error.localizedDescription)
                case .success(.nothing):
                    break
                case .success(.message(let m)):
                    self.show(m)
                case .success(.replace(let range, let with, let select)):
                    guard self.revision == started, tv.string == ctx.text else {
                        return self.show("The note changed while \(plugin.name) ran, so it was left as it is")
                    }
                    if range.length > 200 || range.length == (ctx.text as NSString).length { try? self.vault.snapshot(ctx.text, force: true) }
                    tv.replace(range, with: with, select: select)
                }
            }
        }
    }

    private func refreshStatuses() {
        let stats = NoteStats(text)
        statuses = plugins.filter { $0.status != nil && settings.isOn($0) }.compactMap { $0.status?(text, stats) }
    }

    func show(_ message: String) {
        flash = message
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }

    // MARK: Settings

    private func saveSettings() {
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            try? self.settings.save(to: self.settingsURL)
        }
    }

    func biggerText() { settings.fontSize = min(settings.fontSize + 1, NoteSettings.fontSizes.upperBound) }
    func smallerText() { settings.fontSize = max(settings.fontSize - 1, NoteSettings.fontSizes.lowerBound) }
    func resetText() { settings.fontSize = NoteSettings().fontSize }

    func revealInFinder() {
        flush()
        NSWorkspace.shared.activateFileViewerSelecting([vault.noteURL])
    }

    func openPluginsFolder() {
        ScriptPlugins.prepare(vault.pluginsFolder)
        NSWorkspace.shared.open(vault.pluginsFolder)
    }
}
