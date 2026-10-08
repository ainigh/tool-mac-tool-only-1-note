import Foundation
import XCTest
@testable import NoteCore

final class MarkupTests: XCTestCase {
    func kinds(_ text: String) -> [LineKind] { NoteMarkup.parse(text).map(\.kind) }

    func testTheFirstPlainLineIsTheTitle() {
        XCTAssertEqual(kinds("Groceries\nmilk"), [.title, .plain])
        XCTAssertEqual(kinds("# Big\nsmall"), [.heading(level: 1), .plain])
        XCTAssertEqual(kinds("- a\nb"), [.bullet, .plain])
        XCTAssertEqual(kinds(""), [.blank])
    }

    func testLineKinds() {
        let text = """
        Title
        ## Heading
        - bullet
        * star
        - [ ] open
        - [x] done
          - [X] nested done
        12. twelve
        3) three
        > quote
        ---
        * * *
        #nothash
        -nobullet
        plain
        """
        XCTAssertEqual(kinds(text), [
            .title, .heading(level: 2), .bullet, .bullet, .task(done: false), .task(done: true), .task(done: true),
            .numbered(number: 12), .numbered(number: 3), .quote, .rule, .rule, .plain, .plain, .plain,
        ])
    }

    func testPrefixesAreInUTF16() {
        let lines = NoteMarkup.parse("x\n  - [ ] go\n    - deep\n10. ten\n> q\n### h")
        XCTAssertEqual(lines[1].indent, 2)
        XCTAssertEqual(lines[1].prefix, 8)
        XCTAssertEqual(lines[1].level, 1)
        XCTAssertEqual(lines[2].prefix, 6)
        XCTAssertEqual(lines[2].level, 2)
        XCTAssertEqual(lines[3].prefix, 4)
        XCTAssertEqual(lines[4].prefix, 2)
        XCTAssertEqual(lines[5].prefix, 4)
    }

    func testFencesMakeCode() {
        let text = "T\n```swift\n# not a heading\n- not a bullet\n```\n- a bullet"
        XCTAssertEqual(kinds(text), [.title, .fence, .code, .code, .fence, .bullet])
        // An unclosed fence runs to the end.
        XCTAssertEqual(kinds("T\n```\n- x"), [.title, .fence, .code])
    }

    func testAnEmptyTaskIsStillATask() {
        XCTAssertEqual(kinds("x\n- [ ]"), [.title, .task(done: false)])
        XCTAssertEqual(NoteMarkup.parse("x\n- [ ]")[1].prefix, 5)
        // Not a task: something right after the box.
        XCTAssertEqual(kinds("x\n- [ ]x"), [.title, .bullet])
    }

    func testInlineSpans() {
        let spans = NoteMarkup.spans(in: "a **b** *c* `d *e*` ~~f~~ ==g== _h_")
        XCTAssertEqual(spans.map(\.kind), [.bold, .italic, .code, .strike, .mark, .italic])
        let s = "a **b** x" as NSString
        let bold = NoteMarkup.spans(in: s as String)[0]
        XCTAssertEqual(s.substring(with: bold.range), "**b**")
        XCTAssertEqual(s.substring(with: bold.inner), "b")
    }

    func testInlineSpansAreCareful() {
        XCTAssertTrue(NoteMarkup.spans(in: "2 * 3 * 4").isEmpty)
        XCTAssertTrue(NoteMarkup.spans(in: "snake_case_name").isEmpty)
        XCTAssertTrue(NoteMarkup.spans(in: "** not bold **").isEmpty)
        XCTAssertEqual(NoteMarkup.spans(in: "**bold *with italic* inside**").map(\.kind), [.bold, .italic])
    }

    func testSpansCountUTF16() {
        let s = "😀 **b**" as NSString
        let span = NoteMarkup.spans(in: s as String)[0]
        XCTAssertEqual(span.range.location, 3)
        XCTAssertEqual(s.substring(with: span.inner), "b")
    }
}
