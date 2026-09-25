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
