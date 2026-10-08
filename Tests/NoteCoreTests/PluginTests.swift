import Foundation
import XCTest
@testable import NoteCore

final class PluginTests: XCTestCase {
    /// The note after a plugin's result.
    func apply(_ plugin: NotePlugin, _ text: String, _ selection: NSRange = NSRange(location: 0, length: 0)) throws -> String? {
        let ctx = PluginContext(text: text, selection: selection, now: Date(timeIntervalSince1970: 1_800_000_000),
                                timeZone: TimeZone(identifier: "UTC")!)
        switch try plugin.command!(ctx) {
        case .replace(let range, let with, _): return (text as NSString).replacingCharacters(in: range, with: with)
        default: return nil
        }
    }

    func caret(at s: String, in text: String) -> NSRange {
        NSRange(location: (text as NSString).range(of: s).location, length: 0)
    }

    func testIdsAreUnique() {
        XCTAssertEqual(Set(BuiltInPlugins.all.map(\.id)).count, BuiltInPlugins.all.count)
    }

    func testInsertDate() throws {
        XCTAssertEqual(try apply(BuiltInPlugins.insertDate, "a  b", NSRange(location: 2, length: 0)), "a 2027-01-15 Fri 08:00 b")
    }

    func testStatuses() {
        let stats = NoteStats("T\n- [x] a\n- [ ] b")
        XCTAssertEqual(BuiltInPlugins.wordCount.status!("", stats), "3 words")
        XCTAssertEqual(BuiltInPlugins.taskProgress.status!("", stats), "1 of 2 done")
        XCTAssertNil(BuiltInPlugins.taskProgress.status!("", NoteStats("x")))
    }

    func testChecklistTurnsAParagraphIntoTasksAndBack() throws {
        let text = "T\n\nmilk\n- eggs\n  bread\n\nafter"
        let on = try apply(BuiltInPlugins.checklist, text, caret(at: "eggs", in: text))!
        XCTAssertEqual(on, "T\n\n- [ ] milk\n- [ ] eggs\n  - [ ] bread\n\nafter")
        let off = try apply(BuiltInPlugins.checklist, on, caret(at: "eggs", in: on))!
        XCTAssertEqual(off, "T\n\nmilk\neggs\n  bread\n\nafter")
    }

    func testDoneTasksMoveDownWithWhatsUnderThem() throws {
        let text = "T\n- [x] a\n    note on a\n- [ ] b\n- [x] c\n- [ ] d\n\n- [x] e\n- [ ] f"
        XCTAssertEqual(try apply(BuiltInPlugins.doneToBottom, text),
                       "T\n- [ ] b\n- [ ] d\n- [x] a\n    note on a\n- [x] c\n\n- [ ] f\n- [x] e")
        let ctx = PluginContext(text: "T\n- [ ] a\n- [x] b", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(try BuiltInPlugins.doneToBottom.command!(ctx), .message("Nothing to move"))
    }

    func testClearDone() throws {
        XCTAssertEqual(try apply(BuiltInPlugins.clearDone, "T\n- [x] a\n    - [ ] sub\n- [ ] b\n    - [x] c"), "T\n- [ ] b")
    }

    func testSortLinesByTheirText() throws {
        let text = "T\n- [x] pear\n- [ ] apple\n- banana\n\nz"
        let sorted = try apply(BuiltInPlugins.sortLines, text, caret(at: "pear", in: text))!
        XCTAssertEqual(sorted, "T\n- [ ] apple\n- banana\n- [x] pear\n\nz")
        // Again: Z to A.
        XCTAssertEqual(try apply(BuiltInPlugins.sortLines, sorted, caret(at: "pear", in: sorted)), "T\n- [x] pear\n- banana\n- [ ] apple\n\nz")
        // Numbers sort as numbers.
        let n = "b10\nb9"
        XCTAssertEqual(try apply(BuiltInPlugins.sortLines, n, NSRange(location: 0, length: 6)), "b9\nb10")
    }

    func testRemoveDuplicates() throws {
        XCTAssertEqual(try apply(BuiltInPlugins.removeDuplicates, "a\nb\n\na \n\nb\nc"), "a\nb\n\n\nc")
    }

    func testTidy() throws {
        XCTAssertEqual(try apply(BuiltInPlugins.tidy, "a  \n\n\n\nb\t\n```\nx  \n\n\n```\n\n"), "a\n\nb\n```\nx  \n\n\n```\n")
    }

    func testTheLineBlockAtTheCaret() {
        let text = "a\nb\n\nc\nd"
        let ctx = PluginContext(text: text, selection: NSRange(location: 6, length: 0))
        XCTAssertEqual((text as NSString).substring(with: ctx.lineBlock), "c\nd")
        let sel = PluginContext(text: text, selection: NSRange(location: 1, length: 2))
        XCTAssertEqual((text as NSString).substring(with: sel.lineBlock), "a\nb")
    }
}

final class ScriptPluginTests: XCTestCase {
    var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testManifest() {
        let m = ScriptManifest.parse("""
        #!/usr/bin/env python3
        # @name: Shout it
        # @input: NOTE
        # @output: append
        # @key: S
        # @symbol: speaker
        # email me @ home: not a field
        """, fileName: "shout.py")
        XCTAssertEqual(m, ScriptManifest(name: "Shout it", symbol: "speaker", input: .note, output: .append, key: "s"))
        XCTAssertEqual(ScriptManifest.parse("echo", fileName: "Plain one.sh").name, "Plain one")
    }

    func testTheExamplesRun() throws {
        ScriptPlugins.prepare(folder)
        let plugins = ScriptPlugins.load(from: folder, noteFile: nil)
        XCTAssertEqual(plugins.map(\.name), ["Count lines", "Shout"])
        let text = "Title\n\nhello there"
        let shout = plugins[1]
        let r = try shout.command!(PluginContext(text: text, selection: NSRange(location: 7, length: 5)))
        XCTAssertEqual(r, .replace(range: NSRange(location: 7, length: 5), with: "HELLO", select: true))
        XCTAssertEqual(try plugins[0].command!(PluginContext(text: text, selection: NSRange(location: 0, length: 0))),
                       .message("Count lines: 2 lines with text"))
    }

    func testAFailingScriptSaysWhy() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("bad.sh")
        try "echo nope >&2; exit 3".write(to: url, atomically: true, encoding: .utf8)
        let p = ScriptPlugins.load(from: folder, noteFile: nil)[0]
        XCTAssertThrowsError(try p.command!(PluginContext(text: "x", selection: NSRange(location: 0, length: 0)))) { e in
            XCTAssertEqual((e as? PluginError)?.errorDescription, "bad: nope")
        }
    }

    func testAScriptThatIgnoresItsInputIsFine() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("append.sh")
        try "# @output: append\necho added".write(to: url, atomically: true, encoding: .utf8)
        let p = ScriptPlugins.load(from: folder, noteFile: nil)[0]
        let big = String(repeating: "x", count: 1_000_000)
        let r = try p.command!(PluginContext(text: big, selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(r, .replace(range: NSRange(location: 1_000_000, length: 0), with: "\nadded", select: false))
    }

    func testASlowScriptIsStopped() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("slow.sh")
        try "sleep 5".write(to: url, atomically: true, encoding: .utf8)
        let m = ScriptManifest(name: "slow")
        XCTAssertThrowsError(try ScriptPlugins.run(url, m, PluginContext(text: "x", selection: NSRange(location: 0, length: 0)),
                                                   noteFile: nil, timeout: 0.5))
    }
}
