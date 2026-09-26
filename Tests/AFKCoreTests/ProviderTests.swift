import XCTest
@testable import AFKCore

final class ProviderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "afk.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsKeepGrokForBothStages() {
        XCTAssertEqual(ProviderSettings.provider(for: .speech, defaults), .xai)
        XCTAssertEqual(ProviderSettings.provider(for: .polish, defaults), .xai)
        XCTAssertEqual(ProviderSettings.model(for: .speech, provider: .xai, defaults), "grok-voice-transcribe-2.0")
    }

    func testProviderAndModelChoicesPersistPerProvider() {
        ProviderSettings.setProvider(.openrouter, for: .speech, defaults)
        ProviderSettings.setModel("fish-audio/transcribe-1", for: .speech, provider: .openrouter, defaults)
        ProviderSettings.setProvider(.ollama, for: .polish, defaults)
        ProviderSettings.setModel("qwen2.5:7b", for: .polish, provider: .ollama, defaults)
        XCTAssertEqual(ProviderSettings.provider(for: .speech, defaults), .openrouter)
        XCTAssertEqual(ProviderSettings.model(for: .speech, provider: .openrouter, defaults), "fish-audio/transcribe-1")
        XCTAssertEqual(ProviderSettings.model(for: .polish, provider: .ollama, defaults), "qwen2.5:7b")
        XCTAssertEqual(ProviderSettings.model(for: .polish, provider: .openrouter, defaults), "google/gemini-2.5-flash-lite",
                       "other providers keep their own defaults")
    }

    func testOllamaCannotBeTheSpeechProvider() {
        XCTAssertFalse(Provider.ollama.supports(.speech))
        XCTAssertFalse(Provider.available(for: .speech).contains(.ollama))
        defaults.set("ollama", forKey: "provider.speech")
        XCTAssertEqual(ProviderSettings.provider(for: .speech, defaults), .xai, "falls back to Grok")
    }

    func testExistingXAIModelOverridesStillApply() {
        defaults.set("grok-voice-transcribe-1.0", forKey: "sttModel")
        XCTAssertEqual(ProviderSettings.model(for: .speech, provider: .xai, defaults), "grok-voice-transcribe-1.0")
        XCTAssertEqual(ModelSettings.speechModel(defaults), "grok-voice-transcribe-1.0")
    }

    func testBaseURLOnlyForLocalProviders() {
        ProviderSettings.setBaseURL("http://localhost:1234/v1/", for: .custom, defaults)
        XCTAssertEqual(ProviderSettings.baseURL(for: .custom, defaults), "http://localhost:1234/v1", "trailing slash trimmed")
        ProviderSettings.setBaseURL("https://evil.example", for: .openrouter, defaults)
        XCTAssertEqual(ProviderSettings.baseURL(for: .openrouter, defaults), "https://openrouter.ai/api/v1")
        XCTAssertEqual(ProviderSettings.baseURL(for: .ollama, defaults), "http://localhost:11434/v1")
    }

    func testPerProviderKeysAndEnvironment() {
        XCTAssertEqual(ApiKeyStore.load(for: .openrouter, environment: ["OPENROUTER_API_KEY": " sk-or-1 "])?.key, "sk-or-1")
        XCTAssertNil(ApiKeyStore.load(for: .openai, environment: ["OPENROUTER_API_KEY": "x"]).flatMap { $0.source == .environment ? $0 : nil })
        XCTAssertEqual(Provider.xai.environmentName, "XAI_API_KEY_VOICE")
        XCTAssertEqual(ApiKeyStore.keyFileURL(for: .openrouter).lastPathComponent, "openrouter-api-key")
        XCTAssertEqual(ApiKeyStore.keyFileURL(for: .xai).lastPathComponent, "xai-api-key", "existing xAI key file keeps its name")
        XCTAssertFalse(Provider.ollama.requiresKey)
        XCTAssertTrue(Provider.openrouter.requiresKey)
    }

    func testWavHeader() {
        let pcm = Data(repeating: 1, count: 32_000)
        let wav = OpenAITranscriber.wav(pcm16: pcm, sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 16_000)
    }

    func testTranscriptionRequest() throws {
        let endpoint = Endpoint(provider: .openrouter, apiKey: "sk-or", model: "fish-audio/transcribe-1")
        let req = try XCTUnwrap(OpenAITranscriber.request(pcm: Data(count: 100), endpoint: endpoint, vocabulary: ["GRPO", "宇辰"]))
        XCTAssertEqual(req.url?.absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Title"), "AFK")
        let body = String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("fish-audio/transcribe-1"))
        XCTAssertTrue(body.contains("GRPO, 宇辰"), "vocabulary sent as the prompt hint")
        XCTAssertTrue(body.contains("filename=\"audio.wav\""))

        let local = Endpoint(provider: .custom, baseURL: "http://localhost:8000/v1", apiKey: nil, model: "whisper-1")
        let localReq = try XCTUnwrap(OpenAITranscriber.request(pcm: Data(count: 10), endpoint: local, vocabulary: []))
        XCTAssertNil(localReq.value(forHTTPHeaderField: "Authorization"), "no key, no auth header")
        XCTAssertFalse(String(decoding: localReq.httpBody!, as: UTF8.self).contains("name=\"prompt\""))
    }

    func testChatRequestParametersPerProvider() throws {
        func body(_ e: Endpoint) throws -> [String: Any] {
            let r = Polisher.chatRequest(endpoint: e, messages: [["role": "user", "content": "hi"]], maxTokens: 50, timeout: 4)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
        }
        let ollama = try body(Endpoint(provider: .ollama, apiKey: nil, model: "qwen2.5:7b"))
        XCTAssertEqual(ollama["max_tokens"] as? Int, 50)
        XCTAssertEqual(ollama["temperature"] as? Int, 0)
        let gpt41 = try body(Endpoint(provider: .openai, apiKey: "k", model: "gpt-4.1-mini"))
        XCTAssertEqual(gpt41["max_completion_tokens"] as? Int, 50)
        XCTAssertNil(gpt41["max_tokens"])
        XCTAssertEqual(gpt41["temperature"] as? Int, 0)
        let gpt5 = try body(Endpoint(provider: .openai, apiKey: "k", model: "gpt-5-mini"))
        XCTAssertNil(gpt5["temperature"], "reasoning models reject a custom temperature")
        XCTAssertEqual(Polisher.chatRequest(endpoint: Endpoint(provider: .ollama, apiKey: nil, model: "m"), messages: [], maxTokens: 1, timeout: 1).url?.absoluteString,
                       "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(PolishConfig(endpoint: Endpoint(provider: .ollama, apiKey: nil, model: "m")).timeout, 15, "local models get time to load")
    }

    /// Bodies are real responses observed from OpenRouter.
    func testOpenRouterErrorShapes() {
        func check(_ status: Int, _ body: String) -> KeyCheck { KeyCheck.from(status: status, body: Data(body.utf8), model: "m", seconds: 0) }
        XCTAssertEqual(APIErrorBody.message(from: Data(#"{"error":{"message":"Missing Authentication header","code":401}}"#.utf8)), "Missing Authentication header")
        XCTAssertEqual(APIErrorBody.message(from: Data(#"{"error":"Incorrect API key provided."}"#.utf8)), "Incorrect API key provided.")
        XCTAssertEqual(check(401, #"{"error":{"message":"Missing Authentication header","code":401}}"#), .invalidKey)
        XCTAssertEqual(check(400, #"{"error":{"message":"nope/nope is not a valid model ID","code":400}}"#), .modelNotFound("m"))
        guard case let .noAccess(reason) = check(404, #"{"error":{"message":"0 endpoints out of 1 requested are available matching your guardrail restrictions and data policy."}}"#) else {
            return XCTFail("privacy-blocked model should be reported as no access")
        }
        XCTAssertTrue(reason.contains("privacy"))
        XCTAssertEqual(check(404, #"{"error":"The model 'x' does not exist"}"#), .modelNotFound("m"))
    }

    func testLocalWhisperProvider() {
        XCTAssertTrue(Provider.whisper.supports(.speech))
        XCTAssertFalse(Provider.whisper.supports(.polish))
        XCTAssertFalse(Provider.available(for: .polish).contains(.whisper))
        XCTAssertFalse(Provider.whisper.requiresKey)
        XCTAssertFalse(Provider.whisper.listsModels, "whisper.cpp has no /models, so no Browse button")
        XCTAssertEqual(ProviderSettings.baseURL(for: .whisper, defaults), "http://127.0.0.1:8178/v1")
        let req = OpenAITranscriber.request(pcm: Data(count: 10), endpoint: Endpoint(provider: .whisper, apiKey: nil, model: "whisper"), vocabulary: [])
        XCTAssertEqual(req?.url?.absoluteString, "http://127.0.0.1:8178/v1/audio/transcriptions")
    }

    /// Outputs below are what whisper.cpp's base model actually returned.
    func testWhisperTranscriptCleanup() {
        XCTAssertEqual(OpenAITranscriber.cleanTranscript(" [BLANK_AUDIO]\n"), "", "silence is empty, not text to paste")
        XCTAssertEqual(OpenAITranscriber.cleanTranscript("明天讓宇辰把 Hotshot的FB結果發到,R,L-Day2頻道。\n"),
                       "明天让宇辰把 Hotshot的FB结果发到,R,L-Day2频道。", "Traditional → Simplified")
        XCTAssertEqual(OpenAITranscriber.cleanTranscript(" We fine-tuned it on GitHub.\n"), "We fine-tuned it on GitHub.")
        XCTAssertEqual(OpenAITranscriber.cleanTranscript("(music) Hello [NOISE] there"), "Hello there")
        XCTAssertEqual(OpenAITranscriber.cleanTranscript("Use [brackets] in code"), "Use [brackets] in code", "only all-caps tags are removed")
    }

    func testUnreachableLocalServerMessage() {
        let e = Endpoint(provider: .ollama, apiKey: nil, model: "m")
        XCTAssertEqual(KeyCheck.from(error: URLError(.cannotConnectToHost), endpoint: e),
                       .failed("Can't reach http://localhost:11434/v1 — is the server running?"))
    }
}
