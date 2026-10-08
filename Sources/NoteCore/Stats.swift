import Foundation

/// What the footer can count in the note.
public struct NoteStats: Equatable {
    public var words = 0
    public var characters = 0
    public var lines = 0
    public var tasks = 0
    public var tasksDone = 0

    /// At 230 words a minute, at least one once there's a word.
    public var readingMinutes: Int { words == 0 ? 0 : max(1, Int((Double(words) / 230).rounded())) }

    public init(words: Int = 0, characters: Int = 0, lines: Int = 0, tasks: Int = 0, tasksDone: Int = 0) {
        self.words = words
        self.characters = characters
        self.lines = lines
        self.tasks = tasks
        self.tasksDone = tasksDone
    }

    /// A word is a run of anything but spaces with a letter or a digit in it (so "-" and "[ ]" aren't).
    public init(_ text: String) {
        characters = text.count
        lines = text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        // The words after each line's marker (so a task's "[x]" isn't one).
        let all = NoteMarkup.lines(text)
        for (line, parsed) in zip(all, NoteMarkup.parse(all)) {
            if case .task(let done) = parsed.kind {
                tasks += 1
                if done { tasksDone += 1 }
            }
            words += Self.words(in: parsed.kind == .code ? Substring(line) : Substring(String(decoding: Array(line.utf16).dropFirst(parsed.prefix), as: UTF16.self)))
        }
    }

    /// Runs of anything but spaces with a letter or a digit in them.
    static func words(in text: Substring) -> Int {
        var n = 0
        // Whether the run of non-spaces we're in has been counted yet.
        var counted = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                counted = false
            } else if !counted, CharacterSet.alphanumerics.contains(scalar) {
                n += 1
                counted = true
            }
        }
        return n
    }
}
