import Foundation
import XCTest
@testable import NoteCore

final class EditingTests: XCTestCase {
    func testReturnCarriesListsOn() {
        XCTAssertEqual(NoteEditing.newline(line: "- milk"), .continueWith("- "))
        XCTAssertEqual(NoteEditing.newline(line: "* milk"), .continueWith("* "))
        XCTAssertEqual(NoteEditing.newline(line: "    - deep"), .continueWith("    - "))
        XCTAssertEqual(NoteEditing.newline(line: "- [x] done"), .continueWith("- [ ] "))
        XCTAssertEqual(NoteEditing.newline(line: "9. nine"), .continueWith("10. "))
        XCTAssertEqual(NoteEditing.newline(line: "2) two"), .continueWith("3) "))
        XCTAssertEqual(NoteEditing.newline(line: "> said"), .continueWith("> "))
        XCTAssertEqual(NoteEditing.newline(line: "plain"), .plain)
        XCTAssertEqual(NoteEditing.newline(line: "  indented"), .continueWith("  "))
        XCTAssertEqual(NoteEditing.newline(line: "# Heading"), .plain)
    }

    func testReturnOnAnEmptyItemEndsIt() {
        XCTAssertEqual(NoteEditing.newline(line: "- "), .endList(replacement: ""))
        XCTAssertEqual(NoteEditing.newline(line: "- [ ] "), .endList(replacement: ""))
        XCTAssertEqual(NoteEditing.newline(line: "- [ ]"), .endList(replacement: ""))
        XCTAssertEqual(NoteEditing.newline(line: "3. "), .endList(replacement: ""))
        // A nested one comes back a level first.
        XCTAssertEqual(NoteEditing.newline(line: "    - "), .endList(replacement: "- "))
    }

    func testReturnBeforeTheMarkerIsPlain() {
        XCTAssertEqual(NoteEditing.newline(line: "- milk", before: ""), .plain)
        XCTAssertEqual(NoteEditing.newline(line: "- milk", before: "- mi"), .continueWith("- "))
    }

    func testIndenting() {
        XCTAssertEqual(NoteEditing.indented("- a"), "    - a")
        XCTAssertEqual(NoteEditing.outdented("    - a"), "- a")
        XCTAssertEqual(NoteEditing.outdented("  - a"), "- a")
        XCTAssertEqual(NoteEditing.outdented("\t- a"), "- a")
        XCTAssertEqual(NoteEditing.outdented("- a"), "- a")
    }

    func testTogglingTasks() {
        XCTAssertEqual(NoteEditing.toggledTask("- [ ] go"), "- [x] go")
        XCTAssertEqual(NoteEditing.toggledTask("  - [x] go"), "  - [ ] go")
        XCTAssertEqual(NoteEditing.toggledTask("* [X] go"), "* [ ] go")
        XCTAssertEqual(NoteEditing.toggledTask("- go"), "- [ ] go")
        XCTAssertEqual(NoteEditing.toggledTask("  go"), "  - [ ] go")
        XCTAssertEqual(NoteEditing.toggledTask("1. go"), "- [ ] go")
        XCTAssertEqual(NoteEditing.toggledTask(""), "- [ ] ")
    }

    func testCheckboxRange() {
        XCTAssertEqual(NoteEditing.checkboxRange("  - [ ] x"), NSRange(location: 4, length: 3))
        XCTAssertNil(NoteEditing.checkboxRange("- x"))
    }

    func testRenumbering() {
        let lines = ["1. a", "1. b", "    1. x", "    5. y", "1. c", "", "text", "4. d", "9. e"]
        XCTAssertEqual(NoteEditing.renumbered(lines), ["1. a", "2. b", "    1. x", "    2. y", "3. c", "", "text", "4. d", "5. e"])
    }

    func testStats() {
        let s = NoteStats("Title\n- [ ] one two\n- [x] three\n```\n- [ ] not a task\n```")
        XCTAssertEqual(s.words, 7)
        XCTAssertEqual(s.tasks, 2)
        XCTAssertEqual(s.tasksDone, 1)
        XCTAssertEqual(s.lines, 6)
        XCTAssertEqual(NoteStats("").lines, 0)
        XCTAssertEqual(NoteStats("").readingMinutes, 0)
        XCTAssertEqual(NoteStats("word").readingMinutes, 1)
    }

    func testTheWelcomeNoteShowsEveryKind() {
        let kinds = NoteMarkup.parse(Welcome.text).map(\.kind)
        XCTAssertEqual(kinds.first, .title)
        for k: LineKind in [.heading(level: 1), .bullet, .task(done: true), .task(done: false), .numbered(number: 1), .quote, .rule, .fence, .code] {
            XCTAssertTrue(kinds.contains(k), "\(k)")
        }
    }
}
