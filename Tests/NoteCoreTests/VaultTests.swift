import Foundation
import XCTest
@testable import NoteCore

final class VaultTests: XCTestCase {
    var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAFirstLoadSavesTheWelcome() {
        let v = NoteVault(folder: folder)
        XCTAssertEqual(v.load(welcome: "hi"), "hi")
        XCTAssertEqual(NoteVault(folder: folder).load(welcome: "other"), "hi")
    }

    func testSavingKeepsCopiesNoMoreOftenThanTheInterval() throws {
        let v = NoteVault(folder: folder)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try v.save("one", now: t0)
        try v.save("two", now: t0.addingTimeInterval(60))
        XCTAssertEqual(v.snapshots().count, 1)
        try v.save("three", now: t0.addingTimeInterval(6 * 60))
        XCTAssertEqual(v.snapshots().count, 2)
        XCTAssertEqual(try v.read(v.snapshots()[0]), "three")
        // The same text again: no copy, even forced.
        XCTAssertFalse(try v.snapshot("three", now: t0.addingTimeInterval(20 * 60), force: true))
        // A forced one doesn't wait.
        XCTAssertTrue(try v.snapshot("four", now: t0.addingTimeInterval(6 * 60 + 1), force: true))
        XCTAssertEqual(v.snapshots().count, 3)
        XCTAssertEqual(v.load(), "three")
    }

    func testTwoCopiesInOneSecondBothStay() throws {
        let v = NoteVault(folder: folder)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try v.snapshot("a", now: t, force: true)
        try v.snapshot("b", now: t, force: true)
        let all = v.snapshots()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(try v.read(all[0]), "b")
    }

    func testANewVaultKnowsItsLastCopy() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try NoteVault(folder: folder).save("same", now: t)
        XCTAssertFalse(try NoteVault(folder: folder).snapshot("same", now: t.addingTimeInterval(3600)))
    }

    func testFileNamesRoundTrip() {
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(NoteVault.date(fromFileName: NoteVault.fileName(for: d)), d)
        XCTAssertEqual(NoteVault.date(fromFileName: NoteVault.fileName(for: d, suffix: 2)), d)
        XCTAssertNil(NoteVault.date(fromFileName: "notes.txt"))
        XCTAssertFalse(NoteVault.fileName(for: d).contains(":"))
    }

    func testHistoryThinsAsItAges() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour = 3600.0, day = 24 * hour
        // Every hour for 60 days.
        let dates = (0..<(60 * 24)).map { now.addingTimeInterval(-Double($0) * hour) }
        let removed = Set(NoteHistory.toRemove(dates, now: now))
        let kept = dates.filter { !removed.contains($0) }
        // The last day: all 24. Then one a day to 31 days, then one a week.
        XCTAssertEqual(kept.filter { now.timeIntervalSince($0) < day }.count, 24)
        let month = kept.filter { now.timeIntervalSince($0) >= day && now.timeIntervalSince($0) < 31 * day }
        XCTAssertTrue((29...31).contains(month.count), "\(month.count)")
        let older = kept.filter { now.timeIntervalSince($0) >= 31 * day }
        XCTAssertTrue((4...6).contains(older.count), "\(older.count)")
        XCTAssertTrue(NoteHistory.toRemove([now], now: now).isEmpty)
    }

    func testSettingsReadOldAndOddFiles() throws {
        let s = try JSONDecoder().decode(NoteSettings.self, from: Data(#"{"fontSize": 99, "theme": "neon", "pinned": true}"#.utf8))
        XCTAssertEqual(s.fontSize, NoteSettings.fontSizes.upperBound)
        XCTAssertEqual(s.theme, .auto)
        XCTAssertTrue(s.pinned)
        XCTAssertTrue(s.hotKey)
        let url = folder.appendingPathComponent("settings.json")
        var t = NoteSettings()
        t.plugins["words"] = false
        try t.save(to: url)
        XCTAssertEqual(NoteSettings.load(from: url), t)
        XCTAssertFalse(NoteSettings.load(from: url).isOn(BuiltInPlugins.wordCount))
        XCTAssertFalse(NoteSettings().isOn(BuiltInPlugins.readingTime))
    }
}
