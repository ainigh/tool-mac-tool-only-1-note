import Foundation

// Plugins add to the note without getting in its way. There are two kinds, and one plugin can be
// both:
//
// - a command, run from the footer's puzzle piece (or the Plugins menu, or its key): it gets the
//   note, the selection and the time, and gives back what changes (the selection replaced, the
//   whole note rewritten, or a message for the footer);
// - a status, a few words in the footer worked out from the note as it changes ("230 words").
//
// The built-in ones are below; each can be turned off. More come from the Plugins folder: any
// script there is a command (see `ScriptPlugin`).

/// What a command is given.
public struct PluginContext {
    public var text: String
    /// The selection, in UTF-16 offsets (length 0: the caret).
    public var selection: NSRange
    public var now: Date
    public var timeZone: TimeZone

    public init(text: String, selection: NSRange, now: Date = Date(), timeZone: TimeZone = .current) {
        self.text = text
        self.selection = selection
        self.now = now
        self.timeZone = timeZone
    }

    /// The selected text ("" at a caret).
    public var selectedText: String {
        let s = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= s.length else { return "" }
        return s.substring(with: selection)
    }

    /// The whole lines the selection touches, or, at a caret, the run of lines around it between
    /// blank lines (or the title, or a heading).
    public var lineBlock: NSRange {
        let s = text as NSString
        let sel = NSRange(location: min(selection.location, s.length), length: min(selection.length, max(0, s.length - selection.location)))
        if sel.length > 0 {
            var r = s.lineRange(for: sel)
            // Not the break after the last line.
            if r.length > 0, s.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
            return r
        }
        let lines = Self.lineRanges(s)
        guard let here = lines.lastIndex(where: { $0.location <= sel.location }) else { return NSRange(location: 0, length: 0) }
        func blank(_ i: Int) -> Bool { s.substring(with: lines[i]).trimmingCharacters(in: .whitespaces).isEmpty }
        // A blank line ends the run, and so does the title or a heading (a list under one is its own).
        func heading(_ i: Int) -> Bool {
            let kind = NoteMarkup.parse(s.substring(with: lines[i]), inCode: false, first: i == 0).kind
            if case .heading = kind { return true }
            return kind == .title
        }
        if blank(here) || heading(here) { return lines[here] }
        var a = here, b = here
        while a > 0, !blank(a - 1), !heading(a - 1) { a -= 1 }
        while b < lines.count - 1, !blank(b + 1), !heading(b + 1) { b += 1 }
        return NSRange(location: lines[a].location, length: NSMaxRange(lines[b]) - lines[a].location)
    }

    static func lineRanges(_ s: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = 0
        while true {
            let br = s.range(of: "\n", options: [], range: NSRange(location: start, length: s.length - start))
            guard br.location != NSNotFound else {
                out.append(NSRange(location: start, length: s.length - start))
                return out
            }
            out.append(NSRange(location: start, length: br.location - start))
            start = br.location + 1
        }
    }
}

/// What a command gives back.
public enum PluginResult: Equatable {
    /// `range` (UTF-16, of the note as it was) replaced with `text`, which is then selected when
    /// `select` (else the caret goes after it).
    case replace(range: NSRange, with: String, select: Bool)
    /// A word for the footer.
    case message(String)
    case nothing
}

public struct PluginError: LocalizedError, Equatable {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public struct NotePlugin: Identifiable {
    public enum Source: Equatable {
        case builtIn
        /// A script in the Plugins folder.
        case script(URL)
    }

    public let id: String
    public var name: String
    /// An SF Symbol.
    public var symbol: String
    public var summary: String
    public var source: Source = .builtIn
    /// Its key with ⌃⌥ (a letter or a digit), if it has one.
    public var key: String?
    /// Whether it's on when the app is first run.
    public var onByDefault = true
    public var command: ((PluginContext) throws -> PluginResult)?
    public var status: ((String, NoteStats) -> String?)?

    public init(id: String, name: String, symbol: String, summary: String, source: Source = .builtIn, key: String? = nil,
                onByDefault: Bool = true,
                command: ((PluginContext) throws -> PluginResult)? = nil, status: ((String, NoteStats) -> String?)? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.summary = summary
        self.source = source
        self.key = key
        self.onByDefault = onByDefault
        self.command = command
        self.status = status
    }
}

// MARK: - The built-in plugins

public enum BuiltInPlugins {
    public static let all: [NotePlugin] = [
        wordCount, readingTime, taskProgress, characterCount,
        insertDate, checklist, doneToBottom, clearDone, sortLines, removeDuplicates, renumber, tidy,
    ]

    // MARK: Statuses

    public static let wordCount = NotePlugin(
        id: "words", name: "Word count", symbol: "textformat.abc", summary: "How many words the note has, in the footer.",
        status: { _, stats in stats.words == 1 ? "1 word" : "\(stats.words) words" })

    public static let readingTime = NotePlugin(
        id: "reading-time", name: "Reading time", symbol: "book", summary: "How long the note takes to read, in the footer.",
        onByDefault: false,
        status: { _, stats in stats.words == 0 ? nil : "\(stats.readingMinutes) min read" })

    public static let taskProgress = NotePlugin(
        id: "tasks", name: "Task progress", symbol: "checklist", summary: "How many of the note's tasks are done, in the footer.",
        status: { _, stats in stats.tasks == 0 ? nil : "\(stats.tasksDone) of \(stats.tasks) done" })

    public static let characterCount = NotePlugin(
        id: "characters", name: "Character count", symbol: "character.cursor.ibeam", summary: "How many characters the note has, in the footer.",
        onByDefault: false,
        status: { _, stats in stats.characters == 1 ? "1 character" : "\(stats.characters) characters" })

    // MARK: Commands

    public static let insertDate = NotePlugin(
        id: "insert-date", name: "Insert date and time", symbol: "calendar.badge.clock",
        summary: "Puts today's date and the time at the caret (2026-10-08 Thu 21:40).", key: "d",
        command: { ctx in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = ctx.timeZone
            f.dateFormat = "yyyy-MM-dd EEE HH:mm"
            return .replace(range: ctx.selection, with: f.string(from: ctx.now), select: false)
        })

    public static let checklist = NotePlugin(
        id: "checklist", name: "Make a checklist", symbol: "checklist.unchecked",
        summary: "Turns the selected lines (or the paragraph at the caret) into tasks; on a checklist, back into plain lines.",
        key: "c",
        command: { ctx in
            let block = ctx.lineBlock
            let s = ctx.text as NSString
            let lines = s.substring(with: block).components(separatedBy: "\n")
            let parsed = lines.map { NoteMarkup.parse($0, inCode: false, first: false) }
            let written = lines.indices.filter { parsed[$0].kind != .blank }
            guard !written.isEmpty else { return .nothing }
            let allTasks = written.allSatisfy { if case .task = parsed[$0].kind { return true } else { return false } }
            var out = lines
            for i in written {
                let u = Array(lines[i].utf16)
                if allTasks {
                    out[i] = String(decoding: u.prefix(parsed[i].indent), as: UTF16.self) + String(decoding: u.dropFirst(parsed[i].prefix), as: UTF16.self)
                } else if case .task = parsed[i].kind {
                    continue
                } else {
                    out[i] = NoteEditing.toggledTask(lines[i])
                }
            }
            return .replace(range: block, with: out.joined(separator: "\n"), select: ctx.selection.length > 0)
        })

    public static let doneToBottom = NotePlugin(
        id: "done-to-bottom", name: "Move done tasks down", symbol: "arrow.down.to.line",
        summary: "In each checklist, the done tasks go below the ones still to do (in their order).",
        command: { ctx in
            let lines = NoteMarkup.lines(ctx.text)
            let parsed = NoteMarkup.parse(lines)
            var out: [String] = []
            var i = 0
            while i < lines.count {
                guard case .task = parsed[i].kind, parsed[i].indent == 0 else {
                    out.append(lines[i]); i += 1; continue
                }
                // A checklist: top-level tasks, each with the lines nested under it.
                var open: [[String]] = [], done: [[String]] = []
                while i < lines.count, case .task(let isDone) = parsed[i].kind, parsed[i].indent == 0 {
                    var item = [lines[i]]
                    i += 1
                    while i < lines.count, parsed[i].indent > 0, parsed[i].kind != .blank { item.append(lines[i]); i += 1 }
                    if isDone { done.append(item) } else { open.append(item) }
                }
                out += (open + done).flatMap { $0 }
            }
            let text = out.joined(separator: "\n")
            if text == ctx.text { return .message("Nothing to move") }
            return .replace(range: NSRange(location: 0, length: (ctx.text as NSString).length), with: text, select: false)
        })

    public static let clearDone = NotePlugin(
        id: "clear-done", name: "Clear done tasks", symbol: "checkmark.circle.trianglebadge.exclamationmark",
        summary: "Takes the ticked tasks (and what's nested under them) out of the note. History keeps a copy.",
        command: { ctx in
            let lines = NoteMarkup.lines(ctx.text)
            let parsed = NoteMarkup.parse(lines)
            var out: [String] = []
            var removed = 0
            var i = 0
            while i < lines.count {
                if case .task(true) = parsed[i].kind {
                    let indent = parsed[i].indent
                    i += 1
                    removed += 1
                    while i < lines.count, parsed[i].indent > indent, parsed[i].kind != .blank { i += 1 }
                    continue
                }
                out.append(lines[i])
                i += 1
            }
            if removed == 0 { return .message("No done tasks") }
            return .replace(range: NSRange(location: 0, length: (ctx.text as NSString).length), with: out.joined(separator: "\n"), select: false)
        })

    public static let sortLines = NotePlugin(
        id: "sort-lines", name: "Sort lines", symbol: "arrow.up.arrow.down",
        summary: "Sorts the selected lines (or the paragraph at the caret) A to Z; run it again on sorted lines for Z to A.",
        command: { ctx in
            let block = ctx.lineBlock
            let lines = (ctx.text as NSString).substring(with: block).components(separatedBy: "\n")
            guard lines.count > 1 else { return .message("Select some lines to sort") }
            func key(_ line: String) -> String {
                let p = NoteMarkup.parse(line, inCode: false, first: false)
                return String(decoding: Array(line.utf16).dropFirst(p.prefix), as: UTF16.self)
            }
            let up = lines.sorted { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
            let sorted = up == lines ? Array(up.reversed()) : up
            return .replace(range: block, with: sorted.joined(separator: "\n"), select: ctx.selection.length > 0)
        })

    public static let removeDuplicates = NotePlugin(
        id: "dedupe", name: "Remove duplicate lines", symbol: "minus.square",
        summary: "In the selection (or the whole note), keeps the first of lines that are the same; blank lines stay.",
        command: { ctx in
            let s = ctx.text as NSString
            let range = ctx.selection.length > 0 ? ctx.lineBlock : NSRange(location: 0, length: s.length)
            var seen = Set<String>()
            var removed = 0
            let kept = s.substring(with: range).components(separatedBy: "\n").filter { line in
                let k = line.trimmingCharacters(in: .whitespaces)
                if k.isEmpty || seen.insert(k).inserted { return true }
                removed += 1
                return false
            }
            if removed == 0 { return .message("No duplicate lines") }
            return .replace(range: range, with: kept.joined(separator: "\n"), select: false)
        })

    public static let renumber = NotePlugin(
        id: "renumber", name: "Renumber lists", symbol: "list.number",
        summary: "Numbers every numbered list in order again, from its first number.",
        command: { ctx in
            let lines = NoteMarkup.lines(ctx.text)
            let out = NoteEditing.renumbered(lines)
            if out == lines { return .message("Lists are in order") }
            return .replace(range: NSRange(location: 0, length: (ctx.text as NSString).length), with: out.joined(separator: "\n"), select: false)
        })

    public static let tidy = NotePlugin(
        id: "tidy", name: "Tidy up", symbol: "sparkles",
        summary: "Takes spaces off the ends of lines and runs of blank lines down to one (not inside code).",
        command: { ctx in
            let lines = NoteMarkup.lines(ctx.text)
            let parsed = NoteMarkup.parse(lines)
            var out: [String] = []
            for (line, p) in zip(lines, parsed) {
                if p.kind == .code || p.kind == .fence { out.append(line); continue }
                var t = line
                while let last = t.last, last == " " || last == "\t" { t.removeLast() }
                if t.isEmpty, out.last?.isEmpty == true, out.count > 0 { continue }
                out.append(t)
            }
            while out.count > 1, out.last?.isEmpty == true, out[out.count - 2].isEmpty { out.removeLast() }
            let text = out.joined(separator: "\n")
            if text == ctx.text { return .message("Already tidy") }
            return .replace(range: NSRange(location: 0, length: (ctx.text as NSString).length), with: text, select: false)
        })
}
