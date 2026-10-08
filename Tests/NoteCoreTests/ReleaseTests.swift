import Foundation
import XCTest
@testable import NoteCore

final class ReleaseTests: XCTestCase {
    func testVersionsCompareNumberByNumber() {
        XCTAssertLessThan(Version("0.1.9")!, Version("0.1.12")!)
        XCTAssertLessThan(Version("v0.1")!, Version("0.1.1")!)
        XCTAssertEqual(Version("v1.2.0")!, Version("1.2")!)
        XCTAssertNil(Version("dev"))
        XCTAssertNil(Version("1.2-beta"))
    }

    func testDecodesGitHubsAnswer() throws {
        let json = """
        {"tag_name": "v0.1.14", "target_commitish": "abc123", "body": "Faster", "html_url": "https://github.com/o/r/releases/tag/v0.1.14",
         "assets": [{"name": "OnlyNote.zip", "browser_download_url": "https://github.com/o/r/releases/download/v0.1.14/OnlyNote.zip", "size": 1}]}
        """
        let r = try Release.decode(Data(json.utf8))
        XCTAssertEqual(r.version, Version("0.1.14"))
        XCTAssertEqual(r.asset(named: "OnlyNote.zip")?.browserDownloadURL.lastPathComponent, "OnlyNote.zip")
        XCTAssertEqual(r.target, "abc123")
    }

    func testDecodesACommit() throws {
        let json = """
        {"sha": "0123456789abcdef", "commit": {"message": "Add a tool\\n\\nLonger text", "author": {}}, "files": []}
        """
        let c = try Commit.decode(Data(json.utf8))
        XCTAssertEqual(c.short, "0123456")
        XCTAssertEqual(c.title, "Add a tool")
    }
}
