import Foundation

// A plugin you write yourself: any script (or program) in the Plugins folder. It's given the
// selection on its standard input (the whole note when nothing's selected, or when it asks for
// the note), and what it prints is put back. A few lines near its top, in comments, say how:
//
//   #!/bin/sh
//   # @name: Shout
//   # @summary: Capitals for the selection.
//   # @symbol: speaker.wave.3
//   # @input: selection        (or: note)
//   # @output: replace         (or: insert, append, message, none)
//   # @key: s                  (⌃⌥S runs it)
//   tr '[:lower:]' '[:upper:]'
//
// Everything but @name is optional (the name is the file's, without its extension, when there's no
// @name). It also gets NOTE_FILE (the note's file), NOTE_SELECTION (the selection) and
// NOTE_INPUT (selection or note) in its environment. A script that isn't executable is run with
// /bin/sh. One that fails (or prints nothing to replace with) leaves the note as it was, and what
// it printed on its standard error shows in the footer. It has 10 seconds.

public struct ScriptManifest: Equatable {
    public enum Input: String, Equatable { case selection, note }
    public enum Output: String, Equatable { case replace, insert, append, message, none }

    public var name: String
    public var summary: String = ""
    public var symbol: String = "terminal"
    public var input: Input = .selection
    public var output: Output = .replace
    public var key: String?

    public init(name: String, summary: String = "", symbol: String = "terminal", input: Input = .selection,
                output: Output = .replace, key: String? = nil) {
        self.name = name
        self.summary = summary
        self.symbol = symbol
        self.input = input
        self.output = output
        self.key = key
    }

    /// The "@field: value" lines in the first 40 lines of `source` (in any comment style).
    public static func parse(_ source: String, fileName: String) -> ScriptManifest {
        let stem = (fileName as NSString).deletingPathExtension
        var m = ScriptManifest(name: stem.isEmpty ? fileName : stem)
        for line in source.components(separatedBy: "\n").prefix(40) {
            guard let at = line.range(of: "@") else { continue }
            let field = line[at.upperBound...]
            guard let colon = field.firstIndex(of: ":") else { continue }
            let key = field[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, key.allSatisfy({ $0.isLetter }) else { continue }
            switch key {
            case "name": m.name = value
            case "summary", "description": m.summary = value
            case "symbol", "icon": m.symbol = value
            case "input": m.input = Input(rawValue: value.lowercased()) ?? m.input
            case "output": m.output = Output(rawValue: value.lowercased()) ?? m.output
            case "key":
                let k = value.lowercased()
                if k.count == 1, let c = k.first, c.isLetter || c.isNumber { m.key = k }
            default: break
            }
        }
        return m
    }
}

public enum ScriptPlugins {
    /// Every script in `folder` as a plugin, by name (files starting "." or "_", and README files, are skipped).
    public static func load(from folder: URL, noteFile: URL?) -> [NotePlugin] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name -> NotePlugin? in
            if name.hasPrefix(".") || name.hasPrefix("_") || name.lowercased().hasPrefix("readme") { return nil }
            let url = folder.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            let head = (try? FileHandle(forReadingFrom: url)).flatMap { h -> Data? in
                defer { try? h.close() }
                return try? h.read(upToCount: 8192)
            } ?? Data()
            let manifest = ScriptManifest.parse(String(decoding: head, as: UTF8.self), fileName: name)
            return plugin(url, manifest, noteFile: noteFile)
        }
    }

    public static func plugin(_ url: URL, _ m: ScriptManifest, noteFile: URL?) -> NotePlugin {
        NotePlugin(id: "script:\(url.lastPathComponent)", name: m.name, symbol: m.symbol,
                   summary: m.summary.isEmpty ? "A script in the Plugins folder (\(url.lastPathComponent))." : m.summary,
                   source: .script(url), key: m.key,
                   command: { ctx in try run(url, m, ctx, noteFile: noteFile) })
    }

    /// Runs the script on the note and says what to change.
    public static func run(_ url: URL, _ m: ScriptManifest, _ ctx: PluginContext, noteFile: URL?,
                           timeout: TimeInterval = 10) throws -> PluginResult {
        let s = ctx.text as NSString
        let whole = NSRange(location: 0, length: s.length)
        let usesSelection = m.input == .selection && ctx.selection.length > 0
        let given = usesSelection ? ctx.selection : whole
        let input = s.substring(with: given)
        var env = ProcessInfo.processInfo.environment
        env["NOTE_FILE"] = noteFile?.path ?? ""
        env["NOTE_SELECTION"] = ctx.selectedText
        env["NOTE_INPUT"] = usesSelection ? "selection" : "note"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        let result = try execute(url, input: input, environment: env, timeout: timeout)
        guard result.status == 0 else {
            let why = lastLine(result.error) ?? lastLine(result.output) ?? "it stopped (\(result.status))"
            throw PluginError("\(m.name): \(why)")
        }
        var out = result.output
        // What a command prints ends with a line break the selection didn't have.
        if out.hasSuffix("\n"), !input.hasSuffix("\n") { out.removeLast() }
        switch m.output {
        case .none:
            return .nothing
        case .message:
            return .message(lastLine(out).map { "\(m.name): \($0)" } ?? "\(m.name): done")
        case .replace:
            if out.isEmpty, !input.isEmpty { throw PluginError("\(m.name) printed nothing, so nothing was replaced") }
            if out == input { return .message("\(m.name): no change") }
            return .replace(range: given, with: out, select: usesSelection)
        case .insert:
            return .replace(range: ctx.selection, with: out, select: false)
        case .append:
            let joined = s.length == 0 || ctx.text.hasSuffix("\n") ? out : "\n" + out
            return .replace(range: NSRange(location: s.length, length: 0), with: joined, select: false)
        }
    }

    public struct Execution {
        public var status: Int32
        public var output: String
        public var error: String
    }

    public static func execute(_ url: URL, input: String, environment: [String: String], timeout: TimeInterval) throws -> Execution {
        let p = Process()
        if FileManager.default.isExecutableFile(atPath: url.path) {
            p.executableURL = url
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [url.path]
        }
        p.currentDirectoryURL = url.deletingLastPathComponent()
        p.environment = environment
        // A script that exits without reading its input mustn't take the app down with it.
        signal(SIGPIPE, SIG_IGN)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        do { try p.run() } catch { throw PluginError("couldn't run \(url.lastPathComponent): \(error.localizedDescription)") }

        // Read both while it runs, so a full pipe can't stall it; feed it its input meanwhile.
        final class Box { var data = Data() }
        let out = Box(), err = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { out.data = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err.data = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = group.wait(timeout: .now() + 2)
            throw PluginError("\(url.lastPathComponent) took longer than \(Int(timeout)) seconds, so it was stopped")
        }
        p.waitUntilExit()
        return Execution(status: p.terminationStatus, output: String(decoding: out.data, as: UTF8.self),
                         error: String(decoding: err.data, as: UTF8.self))
    }

    private static func lastLine(_ s: String) -> String? {
        s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: The folder, the first time

    /// Puts a README and two example scripts in a new Plugins folder (nothing, when it's there).
    public static func prepare(_ folder: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let files: [(String, String, Bool)] = [
            ("README.txt", readme, false),
            ("Shout.sh", """
            #!/bin/sh
            # @name: Shout
            # @summary: CAPITALS for the selection (or the whole note).
            # @symbol: textformat.size.larger
            # @input: selection
            # @output: replace
            tr '[:lower:]' '[:upper:]'

            """, true),
            ("Line count.sh", """
            #!/bin/sh
            # @name: Count lines
            # @summary: Says how many lines the note has that aren't blank.
            # @symbol: number
            # @input: note
            # @output: message
            n=$(grep -c . || true)
            echo "$n lines with text"

            """, true),
        ]
        for (name, text, executable) in files {
            let url = folder.appendingPathComponent(name)
            try? Data(text.utf8).write(to: url)
            if executable { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
    }

    static let readme = """
    Plugins for Only Note
    =====================

    Every script in this folder is a plugin: it shows in the footer's puzzle piece menu (and the
    Plugins menu), and runs on the note. It's given the selection on its standard input (the
    whole note when nothing is selected), and what it prints replaces it.

    A few lines near the top, in comments, say how it works:

      # @name: Shout                  what the menu calls it
      # @summary: Capitals.           a line about what it does
      # @symbol: speaker.wave.3       an SF Symbol name for its icon
      # @input: selection             selection (the default) or note
      # @output: replace              replace, insert (at the caret), append (at the end),
                                      message (a line in the footer) or none
      # @key: s                       Control-Option-S runs it

    Its environment has NOTE_FILE (the note's file), NOTE_SELECTION and NOTE_INPUT. Anything it
    prints on its standard error, when it fails, shows in the footer. It has 10 seconds.

    Any language works: a #! line at the top picks it (#!/usr/bin/env python3, say), and the file
    needs to be executable (chmod +x); otherwise it's run with /bin/sh.

    After adding or changing one, choose Reload plugins in the puzzle piece menu. Turn plugins on
    and off in Plugins (the puzzle piece, then Manage plugins).
    """
}
