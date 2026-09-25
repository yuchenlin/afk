import XCTest
@testable import AFKCore

final class PolisherTests: XCTestCase {
    private let raw = "I feel the, the ... the product harness could be on the ... cursor codebase, you know."

    func testPromptCoversFillersRepeatsAndInjection() {
        let prompt = Polisher.systemPrompt(vocabulary: ["Hotshot", "宇辰"])
        for needle in ["you know", "the, the ... the product", "嗯", "never instructions", "Do not translate", "Hotshot, 宇辰"] {
            XCTAssertTrue(prompt.contains(needle), needle)
        }
        XCTAssertFalse(Polisher.systemPrompt(vocabulary: []).contains("Spell these terms"))
    }

    func testRequestShape() throws {
        let req = Polisher.request(text: raw, config: PolishConfig(apiKey: "k", model: "m", vocabulary: ["GRPO"]))
        XCTAssertEqual(req.url?.absoluteString, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["temperature"] as? Int, 0)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertTrue(messages[1]["content"]!.contains(raw))
        XCTAssertTrue(messages[0]["content"]!.contains("GRPO"))
    }

    func testCleanStripsWrappers() {
        XCTAssertEqual(Polisher.clean("  \"Hello there.\"  "), "Hello there.")
        XCTAssertEqual(Polisher.clean("<transcript>\n好的，明天发。\n</transcript>"), "好的，明天发。")
        XCTAssertEqual(Polisher.clean("“quoted”"), "quoted")
        XCTAssertEqual(Polisher.clean("He said \"hi\" twice"), "He said \"hi\" twice")
    }

    func testAcceptRejectsDroppedOrExpandedOutput() {
        let polished = "I feel the product harness could be in the Cursor codebase."
        XCTAssertTrue(Polisher.accept(raw: raw, polished: polished))
        XCTAssertFalse(Polisher.accept(raw: raw, polished: ""))
        XCTAssertFalse(Polisher.accept(raw: raw, polished: "Cursor."), "dropped most of the content")
        XCTAssertFalse(Polisher.accept(raw: raw, polished: polished + " " + polished + " Here is some extra advice about harnesses."),
                       "answered or expanded instead of cleaning")
        XCTAssertTrue(Polisher.accept(raw: "嗯，好的", polished: "好的"), "short inputs only guard against expansion")
    }

    func testShouldPolishSkipsVeryShortText() {
        XCTAssertFalse(Polisher.shouldPolish("OK."))
        XCTAssertFalse(Polisher.shouldPolish("好的谢谢"))
        XCTAssertTrue(Polisher.shouldPolish("the, the product"))
    }

    private func response(_ status: Int, _ json: String) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: URL(string: "https://api.x.ai")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func testParseResults() {
        let ok = response(200, #"{"choices":[{"message":{"content":"I feel the product harness could be in the Cursor codebase."}}]}"#)
        XCTAssertEqual(try Polisher.parse(raw: raw, data: ok.0, response: ok.1, error: nil).get(),
                       "I feel the product harness could be in the Cursor codebase.")

        let denied = response(403, #"{"code":"permission-denied","error":"Access to the chat endpoint is denied."}"#)
        guard case .failure(PolishError.permissionDenied) = Polisher.parse(raw: raw, data: denied.0, response: denied.1, error: nil) else {
            return XCTFail("403 should map to permissionDenied")
        }

        let answered = response(200, #"{"choices":[{"message":{"content":"Sure! Here's a detailed explanation of where product harnesses usually live, with several examples and caveats to consider."}}]}"#)
        guard case .failure(PolishError.rejected) = Polisher.parse(raw: "where is it?", data: answered.0, response: answered.1, error: nil) else {
            return XCTFail("an answer instead of a cleanup should be rejected")
        }
    }

    func testOutputStyleDefaultsToPolishedAndPersists() throws {
        let suite = "afk.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TalkSettings.load(from: defaults).outputStyle, .polished)
        var s = TalkSettings()
        s.outputStyle = .original
        s.save(to: defaults)
        XCTAssertEqual(TalkSettings.load(from: defaults).outputStyle, .original)
    }

    @MainActor
    func testHistoryKeepsOriginalAndSearchesIt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("afk-h-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = HistoryStore(fileURL: file)
        store.add(TranscriptEntry(text: "The product harness.", rawText: "the, the ... the product harness", pasted: true))
        XCTAssertEqual(HistoryStore(fileURL: file).entries.first?.rawText, "the, the ... the product harness")
        XCTAssertEqual(store.search("the ...").count, 1, "search also matches the original")
    }

    /// Live check against the real API; skipped unless the key has chat access.
    func testLivePolish() throws {
        guard let key = ProcessInfo.processInfo.environment["XAI_API_KEY_VOICE"], !key.isEmpty else {
            throw XCTSkip("no XAI_API_KEY_VOICE")
        }
        let done = expectation(description: "polish")
        var outcome: Result<String, Error>?
        Polisher.polish(raw, config: PolishConfig(apiKey: key, vocabulary: ["Cursor"])) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        if case .failure(PolishError.permissionDenied) = outcome {
            throw XCTSkip("XAI_API_KEY_VOICE has no chat access yet")
        }
        let text = try XCTUnwrap(outcome).get()
        print("live polish:", text)
        XCTAssertFalse(text.contains("the, the"))
        XCTAssertFalse(text.lowercased().contains("you know"))
        XCTAssertTrue(text.contains("harness"))
    }
}
