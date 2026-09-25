import XCTest
@testable import AFKCore

final class GrokSttTests: XCTestCase {
    func testAssemblerStreamingSequence() {
        var a = TranscriptAssembler()
        a.apply(text: "Hello, this", isFinal: false, speechFinal: false)
        XCTAssertEqual(a.text, "Hello, this")
        a.apply(text: "Hello, this is a test.", isFinal: true, speechFinal: false)
        a.apply(text: "Second", isFinal: false, speechFinal: false)
        XCTAssertEqual(a.text, "Hello, this is a test. Second")
        a.apply(text: "Hello, this is a test. Second part.", isFinal: true, speechFinal: true)
        XCTAssertEqual(a.text, "Hello, this is a test. Second part.", "utterance final replaces its chunks")
        a.apply(text: "Next", isFinal: false, speechFinal: false)
        XCTAssertEqual(a.text, "Hello, this is a test. Second part. Next")
    }

    func testJoinSpacing() {
        XCTAssertEqual(TranscriptAssembler.join(["Hello.", "World"]), "Hello. World")
        XCTAssertEqual(TranscriptAssembler.join(["今天我们用", "Grok"]), "今天我们用Grok")
        XCTAssertEqual(TranscriptAssembler.join(["测试一下。", "看看"]), "测试一下。看看")
        XCTAssertEqual(TranscriptAssembler.join(["", "  a ", ""]), "a")
    }

    func testApiKeyUsesOnlyVoiceKey() {
        let both = ["XAI_API_KEY_VOICE": "voice", "XAI_API_KEY": "generic"]
        XCTAssertEqual(ApiKeyStore.load(environment: both, keyFile: { "stored" })?.key, "voice")
        XCTAssertEqual(ApiKeyStore.load(environment: both, keyFile: { "stored" })?.source, .environment)

        let genericOnly = ["XAI_API_KEY": "generic", "XAI_API_KEY_VOICE": " "]
        XCTAssertEqual(ApiKeyStore.load(environment: genericOnly, keyFile: { " stored\n" })?.key, "stored")
        XCTAssertNil(ApiKeyStore.load(environment: genericOnly, keyFile: { nil }), "generic XAI_API_KEY is never used")
        XCTAssertNil(ApiKeyStore.load(environment: [:], keyFile: { "  " }))
    }

    func testStreamingURL() throws {
        let config = GrokSttConfig(apiKey: "k", keyterms: ["LoRA", "Model Y", String(repeating: "x", count: 51)])
        let url = GrokSttSession.streamingURL(for: config)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.host, "api.x.ai")
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertTrue(items.contains(URLQueryItem(name: "sample_rate", value: "16000")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "encoding", value: "pcm")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "interim_results", value: "true")))
        XCTAssertEqual(items.filter { $0.name == "keyterm" }.map(\.value), ["LoRA", "Model Y"], "terms over 50 chars dropped")
        XCTAssertFalse(url.absoluteString.contains("k&") || url.absoluteString.contains("apiKey"), "key stays out of the URL")
    }

    func testBatchRequestPutsFileLast() throws {
        let request = GrokBatchStt.request(pcm: Data([1, 2, 3, 4]), config: GrokSttConfig(apiKey: "k", keyterms: ["CUDA"]))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        for field in ["name=\"model\"", "name=\"audio_format\"\r\n\r\npcm", "name=\"sample_rate\"\r\n\r\n16000", "name=\"keyterm\"\r\n\r\nCUDA"] {
            let fieldRange = try XCTUnwrap(body.range(of: field), field)
            let fileRange = try XCTUnwrap(body.range(of: "name=\"file\""))
            XCTAssertLessThan(fieldRange.lowerBound, fileRange.lowerBound, field)
        }
    }
}
