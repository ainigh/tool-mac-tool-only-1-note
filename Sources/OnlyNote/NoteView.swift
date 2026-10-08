import AppKit
import NoteCore
import SwiftUI

/// The whole window: the note, and the footer under it. History, plugins and settings come up
/// over the note when asked for, in the same window.
struct NoteView: View {
    @ObservedObject var model: NoteModel
    @ObservedObject var updater: Updater

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            ZStack {
                EditorView(model: model)
                if let overlay = model.overlay {
                    Color(nsColor: theme.background).opacity(0.6)
                        .onTapGesture { model.overlay = nil }
                    Group {
                        switch overlay {
                        case .history: HistoryView(model: model)
                        case .plugins: PluginsView(model: model)
                        case .settings: SettingsView(model: model, updater: updater)
                        }
                    }
                    .background(Color(nsColor: theme.background))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: theme.rule)))
                    .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.12), radius: 18, y: 6)
                    .padding(14)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.overlay)
            Rectangle().fill(Color(nsColor: theme.rule)).frame(height: 1)
            FooterView(model: model, updater: updater)
        }
        .background(Color(nsColor: theme.background))
        .environment(\.colorScheme, theme.colorScheme)
        .tint(Color(nsColor: theme.accent))
    }
}

/// The text view, in its scroll view.
struct EditorView: NSViewRepresentable {
    let model: NoteModel

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, tv) = NoteTextView.make()
        tv.onEscape = { NSApp.sendAction(#selector(AppDelegate.escape(_:)), to: nil, from: nil) }
        model.attach(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}

// MARK: - The footer

struct FooterView: View {
    @ObservedObject var model: NoteModel
    @ObservedObject var updater: Updater

    private var accent: Color { Color(nsColor: model.theme.accent) }

    var body: some View {
        let theme = model.theme
        HStack(spacing: 10) {
            saveDot
            Group {
                if let running = model.runningPlugin {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("\(running)…")
                    }
                } else if let flash = model.flash {
                    Text(flash).foregroundStyle(Color(nsColor: theme.ink))
                } else {
                    Text(model.statuses.joined(separator: "  ·  "))
                }
            }
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Color(nsColor: theme.secondary))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(model.flash ?? model.statuses.joined(separator: " · "))
            Spacer(minLength: 6)
            UpdateBadge(updater: updater, model: model)
            pluginsMenu
            FooterButton(symbol: "clock.arrow.circlepath", help: "History: every earlier version of the note", on: model.overlay == .history, tint: accent) {
                model.overlay = model.overlay == .history ? nil : .history
            }
            FooterButton(symbol: model.settings.pinned ? "pin.fill" : "pin",
                         help: model.settings.pinned ? "Pinned: the note stays up over other windows. Click to let it hide when you click away."
                                                     : "Pin: keep the note up over other windows while you work",
                         on: model.settings.pinned, tint: accent) {
                model.settings.pinned.toggle()
            }
            FooterButton(symbol: "gearshape", help: "Settings, updates and quit", on: model.overlay == .settings, tint: accent) {
                model.overlay = model.overlay == .settings ? nil : .settings
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 34)
        .background(Color(nsColor: theme.background))
    }

    private var saveDot: some View {
        let theme = model.theme
        let (color, help): (Color, String) = {
            switch model.saveState {
            case .saved: return (Color(nsColor: theme.faint).opacity(0.7), "Saved to \(model.vault.noteURL.path)")
            case .unsaved: return (.orange, "Saving…")
            case .failed(let why): return (.red, "Couldn't save: \(why)")
            }
        }()
        return Circle().fill(color).frame(width: 6, height: 6)
            .help(help)
            .accessibilityLabel(help)
            .onTapGesture { if case .failed = model.saveState { model.save() } }
    }

    private var pluginsMenu: some View {
        Menu {
            let commands = model.commands
            if commands.isEmpty { Text("No plugin commands are on") }
            ForEach(commands) { plugin in
                Button {
                    model.run(plugin)
                } label: {
                    Label(plugin.name + (plugin.key.map { "  ⌃⌥\($0.uppercased())" } ?? ""), systemImage: plugin.symbol)
                }
            }
            Divider()
            Button("Manage plugins…") { model.overlay = .plugins }
            Button("Open the plugins folder") { model.openPluginsFolder() }
            Button("Reload plugins") { model.reloadPlugins() }
        } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 26)
        .foregroundStyle(Color(nsColor: model.theme.secondary))
        .help("Plugins: commands for the note, and what the footer counts")
    }
}

struct FooterButton: View {
    let symbol: String
    let help: String
    var on = false
    var tint: Color = .accentColor
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(on ? tint : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// In the footer only when there's something to say: an update to install, or one installing.
struct UpdateBadge: View {
    @ObservedObject var updater: Updater
    let model: NoteModel

    var body: some View {
        switch updater.state {
        case .available(let update):
            Button {
                model.flush()
                updater.install()
            } label: {
                Label("Update", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(nsColor: model.theme.accent).opacity(0.15)))
                    .foregroundStyle(Color(nsColor: model.theme.accent))
            }
            .buttonStyle(.plain)
            .help("Install the newest version (\(update.commit.short): \(update.commit.title)). The note is saved first; the app restarts.")
        case .installing(let step):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(step).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 200)
        case .failed(let why):
            Button {
                model.overlay = .settings
            } label: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("The last update check failed: \(why)")
        default:
            EmptyView()
        }
    }
}
