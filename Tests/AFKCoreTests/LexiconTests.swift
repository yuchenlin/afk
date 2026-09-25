import XCTest
@testable import AFKCore

final class LexiconTests: XCTestCase {
    func testParsesLinesAndSkipsComments() {
        let text = """
        # comment
        LoRA
        Grok
        """
        XCTAssertEqual(LexiconStore(from: text).terms, ["LoRA", "Grok"])
    }
}

final class VocabularyTests: XCTestCase {
    func testLimitsMatchTheAPI() {
        let long = String(repeating: "x", count: 51)
        var lines = ["# comment", "GRPO", "宇辰", "GRPO", long, "  Hotshot  ", ""]
        lines += (1...105).map { "term\($0)" }
        let lexicon = LexiconStore(from: lines.joined(separator: "\n"))

        XCTAssertEqual(Array(lexicon.terms.prefix(3)), ["GRPO", "宇辰", long], "trimmed, deduped, comments skipped")
        XCTAssertEqual(lexicon.tooLongTerms, [long])
        XCTAssertEqual(lexicon.keyTermsForStt.count, 100)
        XCTAssertFalse(lexicon.keyTermsForStt.contains(long))
        XCTAssertEqual(lexicon.keyTermsForStt.prefix(3), ["GRPO", "宇辰", "Hotshot"])
        XCTAssertEqual(lexicon.overLimitCount, 8, "3 named + 105 generated valid terms, 100 sent")
    }

    func testFiftyCharacterTermIsAllowed() {
        let exact = String(repeating: "字", count: 50)
        XCTAssertEqual(LexiconStore(terms: [exact]).keyTermsForStt, [exact])
    }

    func testSaveAndLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("afk-vocab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nested/lexicon.txt")

        try VocabularyStore.save("GRPO\n宇辰\nrl-data", to: file)
        XCTAssertEqual(VocabularyStore.loadText(fileURL: file), "GRPO\n宇辰\nrl-data\n")
        XCTAssertEqual(VocabularyStore.load(fileURL: file).keyTermsForStt, ["GRPO", "宇辰", "rl-data"])
    }
}
