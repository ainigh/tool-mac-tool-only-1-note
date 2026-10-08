import Foundation

// What the keys do to a line as you type: Return carries a list on (the next bullet, the next
// number, an empty task) or, on an empty item, ends it; Tab and ⇧Tab nest a line deeper or bring it
// back; ⌘↩ ticks a task (or makes the line one). Each takes a line and gives back the new text.

public enum NoteEditing {
    /// One level of nesting.
    public static let indentUnit = "    "

    /// What Return does on a line (with the caret at its end, or splitting it).
    public enum Newline: Equatable {
        /// An ordinary line break.
        case plain
        /// A line break, then this (the next item's marker, or the line's indent).
        case continueWith(String)
        /// The line is an empty item: its marker goes (the line becomes `replacement`), no break.
        case endList(replacement: String)
    }

    /// `before`: the line's text before the caret (what decides whether the item is empty).
    public static func newline(line: String, before: String? = nil) -> Newline {
        let parsed = NoteMarkup.parse(line, inCode: false, first: false)
        let u = Array(line.utf16)
        let indent = String(decoding: u.prefix(parsed.indent), as: UTF16.self)
        let content = String(decoding: u.dropFirst(parsed.prefix), as: UTF16.self)
        let typedBefore = before ?? line
        let caretInMarker = (typedBefore.utf16.count) < parsed.prefix
        switch parsed.kind {
        case .bullet, .task, .numbered, .quote:
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // An empty nested item comes back a level first; an outer one ends the list.
                if parsed.kind != .quote, parsed.indent > 0 { return .endList(replacement: outdented(line)) }
                return .endList(replacement: "")
            }
            if caretInMarker { return .plain }
            let marker = String(decoding: u[parsed.indent..<parsed.prefix], as: UTF16.self)
            switch parsed.kind {
            case .task: return .continueWith(indent + taskMarker(from: marker))
            case .numbered(let n):
                let delimiter = marker.contains(")") ? ")" : "."
                return .continueWith(indent + "\(n + 1)\(delimiter) ")
            default: return .continueWith(indent + marker)
            }
        case .blank, .plain, .title:
            return parsed.indent > 0 ? .continueWith(indent) : .plain
        default:
            return .plain
        }
    }

    /// "- [x] " → "- [ ] ": the next task starts open, with the same bullet.
    private static func taskMarker(from marker: String) -> String {
        let bullet = marker.first.map(String.init) ?? "-"
        return "\(bullet) [ ] "
    }

    /// The line one level deeper.
    public static func indented(_ line: String) -> String { indentUnit + line }

    /// The line one level back (a tab, or up to four spaces, off its start).
    public static func outdented(_ line: String) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        var s = Substring(line)
        var n = 0
        while n < indentUnit.count, s.first == " " { s = s.dropFirst(); n += 1 }
        return String(s)
    }

    /// A task ticked or unticked; any other line made an open task ("- [ ] "), keeping its indent
    /// (a bullet or a number becomes the task's bullet).
    public static func toggledTask(_ line: String) -> String {
        let parsed = NoteMarkup.parse(line, inCode: false, first: false)
        var u = Array(line.utf16)
        switch parsed.kind {
        case .task(let done):
            // The mark is just inside the brackets: indent, bullet, space, "[".
            u[parsed.indent + 3] = done ? UInt16(UInt8(ascii: " ")) : UInt16(UInt8(ascii: "x"))
            return String(decoding: u, as: UTF16.self)
        case .bullet:
            let indent = u.prefix(parsed.indent), bullet = u[parsed.indent]
            return String(decoding: indent + [bullet] + Array(" [ ] ".utf16) + u.dropFirst(parsed.prefix), as: UTF16.self)
        case .numbered, .quote, .heading:
            return String(decoding: u.prefix(parsed.indent), as: UTF16.self) + "- [ ] " + String(decoding: u.dropFirst(parsed.prefix), as: UTF16.self)
        default:
            return String(decoding: u.prefix(parsed.indent), as: UTF16.self) + "- [ ] " + String(decoding: u.dropFirst(parsed.indent), as: UTF16.self)
        }
    }

    /// Where a task's box is in its line (the "[ ]"), in UTF-16 offsets, if it's a task.
    public static func checkboxRange(_ line: String) -> NSRange? {
        let parsed = NoteMarkup.parse(line, inCode: false, first: false)
        guard case .task = parsed.kind else { return nil }
        return NSRange(location: parsed.indent + 2, length: 3)
    }

    /// The numbered items in each run renumbered from the first's number (nested runs on their own).
    /// Only lines whose number changes are touched: the result says which.
    public static func renumbered(_ lines: [String]) -> [String] {
        let parsed = NoteMarkup.parse(lines)
        var out = lines
        // The next number at each indent, for the run going on there.
        var next: [Int: Int] = [:]
        for (i, p) in parsed.enumerated() {
            switch p.kind {
            case .numbered(let n):
                next = next.filter { $0.key <= p.indent }
                let want = next[p.indent] ?? n
                if want != n {
                    let u = Array(lines[i].utf16)
                    let digitsEnd = u[p.indent...].firstIndex { $0 < 48 || $0 > 57 } ?? u.count
                    out[i] = String(decoding: u.prefix(p.indent), as: UTF16.self) + "\(want)" + String(decoding: u[digitsEnd...], as: UTF16.self)
                }
                next[p.indent] = want + 1
            case .bullet, .task:
                next = next.filter { $0.key < p.indent }
            case .blank:
                continue
            default:
                if p.indent == 0 { next = [:] }
            }
        }
        return out
    }
}
