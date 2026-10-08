import Foundation

// The note is plain Markdown-ish text, drawn as you type: the first line is its title, "# " lines
// are headings, "- " lines bullets, "- [ ] " and "- [x] " tasks (a click ticks them), "1. " lines
// numbered, "> " a quote, "---" a rule and ``` fences a block of code. Inline, **bold**, *italic*,
// `code`, ~~struck~~ and ==marked== text. This file only says what each line and span is (in
// UTF-16 offsets, as NSString and NSTextView count); the app decides how it looks.

/// What a line is.
public enum LineKind: Equatable {
    case blank
    /// The note's first line, when it's plain text.
    case title
    case heading(level: Int)
    case bullet
    case task(done: Bool)
    case numbered(number: Int)
    case quote
    case rule
    /// A ``` line, opening or closing a block of code.
    case fence
    /// A line inside a block of code.
    case code
    case plain

    public var isListItem: Bool {
        switch self {
        case .bullet, .task, .numbered: return true
        default: return false
        }
    }
}

/// A line, parsed.
public struct MarkupLine: Equatable {
    public var kind: LineKind
    /// The whitespace it starts with, in UTF-16 units.
    public var indent: Int
    /// The indent and the marker with its space ("  - [ ] "), in UTF-16 units: where its text starts.
    public var prefix: Int
    /// The nesting level of a list item (a tab, or every two spaces, is one).
    public var level: Int

    public init(kind: LineKind, indent: Int = 0, prefix: Int = 0, level: Int = 0) {
        self.kind = kind
        self.indent = indent
        self.prefix = prefix
        self.level = level
    }
}

public enum NoteMarkup {
    /// Every line of a text (split at "\n"; an empty text is one empty line).
    public static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Each line parsed, knowing which are inside a block of code.
    public static func parse(_ lines: [String]) -> [MarkupLine] {
        var out: [MarkupLine] = []
        out.reserveCapacity(lines.count)
        var inCode = false
        for (i, line) in lines.enumerated() {
            let parsed = parse(line, inCode: inCode, first: i == 0)
            if parsed.kind == .fence { inCode.toggle() }
            out.append(parsed)
        }
        return out
    }

    public static func parse(_ text: String) -> [MarkupLine] { parse(lines(text)) }

    /// One line: `inCode` when an open fence is above it, `first` when it's the note's first line.
    public static func parse(_ line: String, inCode: Bool, first: Bool) -> MarkupLine {
        let u = Array(line.utf16)
        var i = 0
        var level = 0, spaces = 0
        while i < u.count, u[i] == space || u[i] == tab {
            if u[i] == tab { level += 1; spaces = 0 } else { spaces += 1; if spaces == 2 { level += 1; spaces = 0 } }
            i += 1
        }
        let indent = i
        let rest = u[i...]
        if isFence(rest) { return MarkupLine(kind: .fence, indent: indent, prefix: u.count) }
        if inCode { return MarkupLine(kind: .code) }
        if rest.isEmpty { return MarkupLine(kind: .blank, indent: indent, prefix: indent) }

        // A heading: one to six "#" then a space.
        if indent == 0 {
            var hashes = 0
            while hashes < rest.count, rest[rest.startIndex + hashes] == hash { hashes += 1 }
            if (1...6).contains(hashes), rest.count > hashes, rest[rest.startIndex + hashes] == space {
                return MarkupLine(kind: .heading(level: hashes), prefix: hashes + 1)
            }
        }
        if isRule(rest) { return MarkupLine(kind: .rule, indent: indent, prefix: u.count) }
        // A quote.
        if rest.first == gt {
            let p = rest.count > 1 && rest[rest.startIndex + 1] == space ? 2 : 1
            return MarkupLine(kind: .quote, indent: indent, prefix: indent + p)
        }
        // A bullet, or a task.
        if let c = rest.first, c == dash || c == star || c == plus, rest.count >= 2, rest[rest.startIndex + 1] == space {
            let after = rest.dropFirst(2)
            if after.count >= 3, after[after.startIndex] == open, after[after.startIndex + 2] == close,
               after.count == 3 || after[after.startIndex + 3] == space {
                let mark = after[after.startIndex + 1]
                if mark == space || mark == x || mark == bigX {
                    let p = indent + 2 + 3 + (after.count > 3 ? 1 : 0)
                    return MarkupLine(kind: .task(done: mark != space), indent: indent, prefix: p, level: level)
                }
            }
            return MarkupLine(kind: .bullet, indent: indent, prefix: indent + 2, level: level)
        }
        // A numbered line: digits, "." or ")", a space.
        var digits = 0
        while digits < rest.count, digits < 9, let d = rest.dropFirst(digits).first, d >= zero, d <= nine { digits += 1 }
        if digits > 0, rest.count > digits + 1 {
            let delimiter = rest[rest.startIndex + digits]
            if delimiter == dot || delimiter == paren, rest[rest.startIndex + digits + 1] == space {
                let number = Int(String(decoding: rest.prefix(digits), as: UTF16.self)) ?? 1
                return MarkupLine(kind: .numbered(number: number), indent: indent, prefix: indent + digits + 2, level: level)
            }
        }
        if first { return MarkupLine(kind: .title, indent: indent, prefix: indent) }
        return MarkupLine(kind: .plain, indent: indent, prefix: indent)
    }

    // MARK: Inline

    public enum SpanKind: Equatable {
        case bold, italic, code, strike, mark
    }

    /// A styled run in a line: `range` is all of it, markers included; `inner` the text between them.
    public struct Span: Equatable {
        public var kind: SpanKind
        public var range: NSRange
        public var inner: NSRange
    }

    private static let patterns: [(SpanKind, NSRegularExpression, Int)] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        // (kind, pattern, marker length). Code first: nothing inside it is anything else.
        return [
            (.code, re("`([^`\\n]+)`"), 1),
            (.bold, re("\\*\\*(?=\\S)([^\\n]*?\\S)\\*\\*"), 2),
            (.bold, re("(?<![\\w_])__(?=\\S)([^\\n]*?\\S)__(?![\\w_])"), 2),
            (.strike, re("~~(?=\\S)([^\\n]*?\\S)~~"), 2),
            (.mark, re("==(?=\\S)([^\\n]*?\\S)=="), 2),
            (.italic, re("(?<![\\*\\w])\\*(?=[^\\s\\*])([^\\n\\*]*?[^\\s\\*])\\*(?![\\*\\w])"), 1),
            (.italic, re("(?<![\\w_])_(?=[^\\s_])([^\\n_]*?[^\\s_])_(?![\\w_])"), 1),
        ]
    }()

    /// The styled runs in `text` within `range` (a line, usually), in UTF-16 offsets of `text`.
    /// Nothing is found inside `code`, and runs of a kind don't overlap.
    public static func spans(in text: NSString, range: NSRange) -> [Span] {
        var out: [Span] = []
        var codeRanges: [NSRange] = []
        for (kind, re, marker) in patterns {
            for m in re.matches(in: text as String, range: range) {
                let r = m.range
                if codeRanges.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
                if kind != .code, out.contains(where: { $0.kind == kind && NSIntersectionRange($0.range, r).length > 0 }) { continue }
                let inner = NSRange(location: r.location + marker, length: r.length - 2 * marker)
                out.append(Span(kind: kind, range: r, inner: inner))
                if kind == .code { codeRanges.append(r) }
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    public static func spans(in line: String) -> [Span] {
        let s = line as NSString
        return spans(in: s, range: NSRange(location: 0, length: s.length))
    }

    // MARK: Characters

    private static let space = UInt16(UInt8(ascii: " ")), tab = UInt16(UInt8(ascii: "\t"))
    private static let hash = UInt16(UInt8(ascii: "#")), gt = UInt16(UInt8(ascii: ">"))
    private static let dash = UInt16(UInt8(ascii: "-")), star = UInt16(UInt8(ascii: "*")), plus = UInt16(UInt8(ascii: "+"))
    private static let underscore = UInt16(UInt8(ascii: "_")), backtick = UInt16(UInt8(ascii: "`"))
    private static let open = UInt16(UInt8(ascii: "[")), close = UInt16(UInt8(ascii: "]"))
    private static let x = UInt16(UInt8(ascii: "x")), bigX = UInt16(UInt8(ascii: "X"))
    private static let zero = UInt16(UInt8(ascii: "0")), nine = UInt16(UInt8(ascii: "9"))
    private static let dot = UInt16(UInt8(ascii: ".")), paren = UInt16(UInt8(ascii: ")"))

    private static func isFence(_ s: ArraySlice<UInt16>) -> Bool {
        s.count >= 3 && s.prefix(3).allSatisfy { $0 == backtick }
    }

    /// "---", "***" or "___" (three or more, spaces between them allowed).
    private static func isRule(_ s: ArraySlice<UInt16>) -> Bool {
        let marks = s.filter { $0 != space && $0 != tab }
        guard marks.count >= 3, let c = marks.first, c == dash || c == star || c == underscore else { return false }
        return marks.allSatisfy { $0 == c }
    }
}
