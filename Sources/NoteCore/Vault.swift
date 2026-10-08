import Foundation

// Where the note lives: one plain Markdown file, Note.md, in
// ~/Library/Application Support/OnlyNote (any editor can open it; the app picks up changes made
// there). Every save is atomic (written beside it, then swapped in), so a crash never leaves half a
// note. And a history: a copy of the note in History/ at most every few minutes while it changes,
// and before anything that rewrites it all (a plugin, a restore, a change from outside), thinned
// as it ages so it never grows without end.

public final class NoteVault {
    public let folder: URL
    public var noteURL: URL { folder.appendingPathComponent("Note.md") }
    public var historyFolder: URL { folder.appendingPathComponent("History", isDirectory: true) }
    public var pluginsFolder: URL { folder.appendingPathComponent("Plugins", isDirectory: true) }

    /// The least time between two copies made while typing.
    public var snapshotInterval: TimeInterval = 5 * 60

    /// The text of the newest copy in History/ (to skip a copy that's the same), and when it was made.
    private var lastSnapshot: (date: Date, text: String)?

    public init(folder: URL) {
        self.folder = folder
        if let newest = snapshots().first, let text = try? read(newest) {
            lastSnapshot = (newest.date, text)
        }
    }

    /// ~/Library/Application Support/OnlyNote
    public static var standardFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OnlyNote", isDirectory: true)
    }

    // MARK: The note

    /// The note's text; `welcome` (saved) when there's no note yet.
    public func load(welcome: String = "") -> String {
        if let data = try? Data(contentsOf: noteURL) {
            return String(decoding: data, as: UTF8.self)
        }
        try? save(welcome)
        return welcome
    }

    /// Writes the note (atomically), then keeps a copy in History/ when it's been a while.
    public func save(_ text: String, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: noteURL, options: .atomic)
        try snapshot(text, now: now)
    }

    /// When the note's file was last written (by the app or anything else).
    public func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: noteURL.path))?[.modificationDate] as? Date
    }

    // MARK: History

    public struct Snapshot: Equatable, Identifiable {
        public let date: Date
        public let url: URL
        public var id: URL { url }
    }

    /// Keeps a copy of `text` in History/ unless it's the same as the last copy, or (unless
    /// `force`) the last was made less than `snapshotInterval` ago. Returns whether it did.
    @discardableResult
    public func snapshot(_ text: String, now: Date = Date(), force: Bool = false) throws -> Bool {
        if let last = lastSnapshot {
            if last.text == text { return false }
            if !force, now.timeIntervalSince(last.date) < snapshotInterval { return false }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, lastSnapshot == nil { return false }
        try FileManager.default.createDirectory(at: historyFolder, withIntermediateDirectories: true)
        var url = historyFolder.appendingPathComponent(Self.fileName(for: now))
        // Two in the same second (a forced one right after another): the later wins its own name.
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = historyFolder.appendingPathComponent(Self.fileName(for: now, suffix: n))
            n += 1
        }
        try Data(text.utf8).write(to: url, options: .atomic)
        lastSnapshot = (now, text)
        prune(now: now)
        return true
    }

    /// The copies in History/, newest first.
    public func snapshots() -> [Snapshot] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: historyFolder.path)) ?? []
        return names.compactMap { name in
            Self.date(fromFileName: name).map { Snapshot(date: $0, url: historyFolder.appendingPathComponent(name)) }
        }
        .sorted { $0.date == $1.date ? Self.suffix($0.url.lastPathComponent) > Self.suffix($1.url.lastPathComponent) : $0.date > $1.date }
    }

    public func read(_ snapshot: Snapshot) throws -> String {
        String(decoding: try Data(contentsOf: snapshot.url), as: UTF8.self)
    }

    /// Thins History/ (`NoteHistory.toRemove`).
    public func prune(now: Date = Date()) {
        let all = snapshots()
        let remove = Set(NoteHistory.toRemove(all.map(\.date), now: now))
        for s in all where remove.contains(s.date) {
            try? FileManager.default.removeItem(at: s.url)
        }
    }

    // MARK: Names

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f
    }()

    /// "2026-10-08T21-40-05Z.md" (no colons: Finder shows them as slashes).
    public static func fileName(for date: Date, suffix: Int? = nil) -> String {
        formatter.string(from: date) + (suffix.map { " \($0)" } ?? "") + ".md"
    }

    /// The " 2" in "…Z 2.md" (1 when there's none): which of the copies made in one second came later.
    static func suffix(_ name: String) -> Int {
        let stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        let parts = stem.split(separator: " ")
        return parts.count > 1 ? Int(parts[1]) ?? 1 : 1
    }

    public static func date(fromFileName name: String) -> Date? {
        guard name.hasSuffix(".md") else { return nil }
        let stem = name.dropLast(3)
        let stamp = stem.split(separator: " ").first.map(String.init) ?? String(stem)
        return formatter.date(from: stamp)
    }
}

/// How the history thins as it ages: every copy from the last day, the newest copy of each day for
/// the last month, then the newest of each week; and never more than `limit` in all.
public enum NoteHistory {
    public static let limit = 400

    public static func toRemove(_ dates: [Date], now: Date, calendar: Calendar = .init(identifier: .gregorian)) -> [Date] {
        var cal = calendar
        cal.timeZone = TimeZone(identifier: "UTC")!
        let newest = dates.sorted(by: >)
        var keep: [Date] = []
        var days = Set<DateComponents>(), weeks = Set<DateComponents>()
        for d in newest {
            let age = now.timeIntervalSince(d)
            if age < 24 * 3600 {
                keep.append(d)
            } else if age < 31 * 24 * 3600 {
                if days.insert(cal.dateComponents([.year, .month, .day], from: d)).inserted { keep.append(d) }
            } else {
                if weeks.insert(cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)).inserted { keep.append(d) }
            }
        }
        let kept = Set(keep.prefix(limit))
        return newest.filter { !kept.contains($0) }
    }
}
