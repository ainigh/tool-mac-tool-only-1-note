import AppKit
import NoteCore
import ServiceManagement
import SwiftUI

/// The top of an overlay: its title, and a close button (Esc closes it too).
struct OverlayHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

// MARK: - History

/// Every copy the history keeps, newest first: pick one to read it, and restore it (the note as it
/// is now is kept too, and ⌘Z undoes the restore).
struct HistoryView: View {
    @ObservedObject var model: NoteModel
    @State private var snapshots: [NoteVault.Snapshot] = []
    @State private var picked: NoteVault.Snapshot?
    @State private var preview = ""

    var body: some View {
        VStack(spacing: 0) {
            OverlayHeader(title: "History") { model.overlay = nil }
            if snapshots.isEmpty {
                Spacer()
                Text("No earlier versions yet.\nA copy is kept every few minutes while the note changes.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Spacer()
            } else {
                List(snapshots, selection: Binding(get: { picked?.id }, set: { id in pick(snapshots.first { $0.id == id }) })) { s in
                    HStack {
                        Text(NoteModel.when(s.date))
                        Spacer()
                        Text(s.date, style: .relative).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .tag(s.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 190)
                Divider()
                ScrollView {
                    Text(preview.isEmpty ? " " : preview)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                        .padding(14)
                }
                Divider()
                HStack {
                    if let picked {
                        let stats = NoteStats(preview)
                        Text("\(stats.words) words").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(preview, forType: .string)
                        }
                        Button("Restore this version") { model.restore(picked) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Spacer()
                    }
                }
                .controlSize(.small)
                .padding(12)
            }
        }
        .onAppear {
            model.flush()
            snapshots = model.vault.snapshots()
            pick(snapshots.first)
        }
    }

    private func pick(_ s: NoteVault.Snapshot?) {
        picked = s
        preview = s.flatMap { try? model.vault.read($0) } ?? ""
    }
}

// MARK: - Plugins

struct PluginsView: View {
    @ObservedObject var model: NoteModel

    var body: some View {
        VStack(spacing: 0) {
            OverlayHeader(title: "Plugins") { model.overlay = nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("In the footer", model.plugins.filter { $0.status != nil })
                    section("Commands (the puzzle piece, or their keys)", model.plugins.filter { $0.command != nil && $0.source == .builtIn })
                    let scripts = model.plugins.filter { $0.source != .builtIn }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your scripts").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        if scripts.isEmpty {
                            Text("None yet. Any script in the plugins folder is a command: it gets the selection (or the note) and what it prints replaces it. The folder's README says how.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(scripts) { row($0) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            Divider()
            HStack {
                Button("Open the plugins folder") { model.openPluginsFolder() }
                Spacer()
                Button("Reload") { model.reloadPlugins() }
            }
            .controlSize(.small)
            .padding(12)
        }
    }

    private func section(_ title: String, _ plugins: [NotePlugin]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(plugins) { row($0) }
        }
    }

    private func row(_ plugin: NotePlugin) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: plugin.symbol)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.name).font(.system(size: 12.5, weight: .medium))
                    if let key = plugin.key {
                        Text("⌃⌥\(key.uppercased())").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                Text(plugin.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.settings.isOn(plugin) }, set: { model.setPlugin(plugin, on: $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: NoteModel
    @ObservedObject var updater: Updater
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            OverlayHeader(title: "Settings") { model.overlay = nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("Look") {
                        row("Theme") {
                            Picker("", selection: $model.settings.theme) {
                                ForEach(NoteSettings.Theme.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                        }
                        row("Typeface") {
                            Picker("", selection: $model.settings.typeface) {
                                ForEach(NoteSettings.Typeface.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 250)
                        }
                        row("Size") {
                            HStack {
                                Slider(value: $model.settings.fontSize, in: NoteSettings.fontSizes, step: 1).frame(width: 150)
                                Text("\(Int(model.settings.fontSize)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                        row("Line spacing") {
                            Slider(value: $model.settings.lineSpacing, in: 1...2).frame(width: 150)
                        }
                        Toggle("Keep lines to a readable width", isOn: $model.settings.readableWidth)
                        Toggle("Check spelling as I type", isOn: $model.settings.spellCheck)
                    }
                    group("Window") {
                        Toggle("Pin: stay up over other windows", isOn: $model.settings.pinned)
                        Toggle("⌥⌘N shows and hides the note from anywhere", isOn: $model.settings.hotKey)
                        Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
                    }
                    group("The note") {
                        HStack {
                            Text(model.vault.noteURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Show in Finder") { model.revealInFinder() }
                        }
                        Text("A plain Markdown file: any editor can open it, and changes made there show up here.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    group("Updates") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Version \(Updater.currentVersion)").font(.system(size: 12.5, weight: .medium))
                                Text(updateText).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if case .available = updater.state {
                                Button("Update now") { model.flush(); updater.install() }.keyboardShortcut(.defaultAction)
                            } else {
                                Button("Check now") { updater.check(userInitiated: true) }
                                    .disabled(updater.state == .checking || isInstalling)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            Divider()
            HStack {
                Text("Only Note").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { model.flush(); NSApp.terminate(nil) }
            }
            .controlSize(.small)
            .padding(12)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12.5))
        .onAppear { openAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private var isInstalling: Bool {
        if case .installing = updater.state { return true }
        return false
    }

    private var updateText: String {
        switch updater.state {
        case .idle: return "Checks GitHub at launch and every few hours."
        case .checking: return "Checking…"
        case .upToDate: return "Up to date."
        case .available(let u): return "New: \(u.commit.title) (\(u.commit.short))" + (u.release == nil ? ", built on this Mac" : "")
        case .installing(let step): return step
        case .failed(let why): return Updater.report(why)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(label)
            Spacer()
            content()
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            model.show("Open at login: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
