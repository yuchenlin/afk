import XCTest
@testable import AFKCore

@MainActor
final class HistoryTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("history.json") }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("afk-history-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func entry(_ text: String, minutesAgo: Double, app: String? = "Slack", pasted: Bool = true) -> TranscriptEntry {
        TranscriptEntry(date: Date().addingTimeInterval(-minutesAgo * 60), text: text, duration: 2.5, appName: app, pasted: pasted)
    }

    func testAddPersistsNewestFirstAcrossRestarts() throws {
        let store = HistoryStore(fileURL: file)
        XCTAssertTrue(store.entries.isEmpty)
        store.add(entry("first", minutesAgo: 2))
        store.add(entry("明天让宇辰发 eval", minutesAgo: 1))
        XCTAssertEqual(store.entries.map(\.text), ["明天让宇辰发 eval", "first"])

        let reloaded = HistoryStore(fileURL: file)
        XCTAssertEqual(reloaded.entries.map(\.id), store.entries.map(\.id))
        XCTAssertEqual(reloaded.entries.map(\.text), store.entries.map(\.text))
        for (a, b) in zip(reloaded.entries, store.entries) {
            XCTAssertEqual(a.date.timeIntervalSince1970, b.date.timeIntervalSince1970, accuracy: 0.001)
        }
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "history is private to the user")
    }

    func testDeleteAndClear() {
        let store = HistoryStore(fileURL: file)
        let a = entry("a", minutesAgo: 3), b = entry("b", minutesAgo: 2), c = entry("c", minutesAgo: 1)
        [a, b, c].forEach(store.add)
        store.delete(ids: [a.id, c.id])
        XCTAssertEqual(store.entries.map(\.text), ["b"])
        XCTAssertEqual(HistoryStore(fileURL: file).entries.map(\.text), ["b"])

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(HistoryStore(fileURL: file).entries.isEmpty)
    }

    func testSearchMatchesTextAndAppInsensitively() {
        let store = HistoryStore(fileURL: file)
        store.add(entry("We trained with GRPO", minutesAgo: 3, app: "Slack"))
        store.add(entry("Café meeting notes", minutesAgo: 2, app: "Notes"))
        store.add(entry("明天让宇辰发 eval", minutesAgo: 1, app: "Cursor"))
        XCTAssertEqual(store.search("grpo").map(\.text), ["We trained with GRPO"])
        XCTAssertEqual(store.search("cafe").map(\.text), ["Café meeting notes"])
        XCTAssertEqual(store.search("宇辰").map(\.text), ["明天让宇辰发 eval"])
        XCTAssertEqual(store.search("cursor").count, 1, "matches the app name")
        XCTAssertEqual(store.search("  ").count, 3)
        XCTAssertTrue(store.search("nothing").isEmpty)
    }

    func testUnreadableFileIsKeptNotOverwritten() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = HistoryStore(fileURL: file)
        XCTAssertTrue(store.entries.isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("history-unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(aside[0]), encoding: .utf8), "not json")
        store.add(entry("new", minutesAgo: 0))
        XCTAssertEqual(HistoryStore(fileURL: file).entries.map(\.text), ["new"])
    }
}
