import XCTest
@testable import AFKCore

final class LexiconTests: XCTestCase {
    func testParsesLinesAndSkipsComments() {
        let text = """
        # comment
        LoRA
        Grok

        CUDA
        """
        let lex = LexiconStore(from: text)
        XCTAssertEqual(lex.terms, ["LoRA", "Grok", "CUDA"])
    }
}
