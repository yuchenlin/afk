import XCTest
@testable import AFKCore

final class SettingsTests: XCTestCase {
    func testKeySaveWritesPrivateFileAndEmptyRemovesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("afk-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("AFK/xai-api-key")

        try ApiKeyStore.save("  xai-abc123def456  \n", to: file)
        XCTAssertEqual(ApiKeyStore.readKeyFile(at: file), "xai-abc123def456")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(dirAttrs[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(ApiKeyStore.load(environment: [:], keyFile: { ApiKeyStore.readKeyFile(at: file) })?.source, .keyFile)

        try ApiKeyStore.save("   ", to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMaskedNeverRevealsTheMiddle() {
        XCTAssertEqual(ApiKeyStore.masked("xai-ABCDEFGHIJKLMNOP1234"), "xai-…1234")
        XCTAssertEqual(ApiKeyStore.masked("short"), "•••••")
    }

    func testModelSettingsOverridesAndDefaults() throws {
        let suite = "afk.tests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ModelSettings.speechModel(d), "grok-voice-transcribe-2.0")
        XCTAssertEqual(ModelSettings.polishModel(d), PolishConfig.defaultModel)

        ModelSettings.save(speech: "grok-voice-transcribe-1.0", polish: " grok-4-fast-non-reasoning ", to: d)
        XCTAssertEqual(ModelSettings.speechModel(d), "grok-voice-transcribe-1.0")
        XCTAssertEqual(ModelSettings.polishModel(d), "grok-4-fast-non-reasoning")

        ModelSettings.save(speech: "", polish: PolishConfig.defaultModel, to: d)
        XCTAssertNil(d.string(forKey: "sttModel"), "empty clears the override")
        XCTAssertNil(d.string(forKey: "polishModel"), "saving the default clears the override")
    }

    /// Bodies below are the real responses observed from api.x.ai.
    func testKeyCheckMapping() {
        func check(_ status: Int, _ body: String, model: String = "m") -> KeyCheck {
            KeyCheck.from(status: status, body: Data(body.utf8), model: model, seconds: 0.3)
        }
        XCTAssertEqual(check(200, #"{"text":""}"#), .ok(seconds: 0.3))
        XCTAssertEqual(check(400, #"{"code":"invalid-argument","error":"Incorrect API key provided. You can obtain an API key from https://console.x.ai."}"#), .invalidKey)
        XCTAssertEqual(check(403, #"{"code":"permission-denied","error":"Access to the chat endpoint is denied."}"#),
                       .noAccess("Access to the chat endpoint is denied."))
        XCTAssertEqual(check(403, #"{"error":"API key is currently blocked"}"#), .noAccess("API key is currently blocked"))
        XCTAssertEqual(check(404, #"{"error":"The model 'grok-voice-nope' does not exist"}"#, model: "grok-voice-nope"),
                       .modelNotFound("grok-voice-nope"))
        XCTAssertEqual(check(400, #"{"error":"format=true requires language"}"#), .failed("HTTP 400: format=true requires language"))
        XCTAssertEqual(check(503, "oops"), .failed("HTTP 503: oops"))
    }

    @MainActor
    func testTranscriptionErrorsThatNeedSettings() {
        XCTAssertEqual(AppDelegate.apiProblem(for: GrokSttError.http(400, #"{"error":"Incorrect API key provided."}"#), provider: .xai), "xAI Grok API key rejected")
        XCTAssertEqual(AppDelegate.apiProblem(for: GrokSttError.http(403, #"{"error":"API key is currently blocked"}"#), provider: .xai), "xAI Grok key has no speech-to-text access")
        XCTAssertEqual(AppDelegate.apiProblem(for: GrokSttError.http(401, #"{"error":{"message":"Missing Authentication header"}}"#), provider: .openrouter), "OpenRouter API key rejected")
        XCTAssertNil(AppDelegate.apiProblem(for: GrokSttError.http(503, "busy")))
        XCTAssertNil(AppDelegate.apiProblem(for: URLError(.notConnectedToInternet)))
    }

    /// Live: the real key passes both checks; a bad key and an unknown model are named precisely.
    func testLiveKeyTester() throws {
        guard let key = ProcessInfo.processInfo.environment["XAI_API_KEY_VOICE"], !key.isEmpty else {
            throw XCTSkip("no XAI_API_KEY_VOICE")
        }
        func run(_ key: String, speech: String = ModelSettings.defaultSpeechModel, polish: String = ModelSettings.defaultPolishModel) -> ApiKeyTester.Result? {
            let done = expectation(description: "test")
            var result: ApiKeyTester.Result?
            ApiKeyTester.test(key: key, speechModel: speech, polishModel: polish) { result = $0; done.fulfill() }
            wait(for: [done], timeout: 30)
            return result
        }
        let good = try XCTUnwrap(run(key))
        XCTAssertTrue(good.speech.isOK, good.speech.summary)
        XCTAssertTrue(good.polish.isOK, good.polish.summary)

        let bad = try XCTUnwrap(run("xai-not-a-real-key"))
        XCTAssertEqual(bad.speech, .invalidKey)
        XCTAssertEqual(bad.polish, .invalidKey)

        let wrongModels = try XCTUnwrap(run(key, speech: "grok-voice-nope", polish: "grok-nope"))
        XCTAssertEqual(wrongModels.speech, .modelNotFound("grok-voice-nope"))
        XCTAssertEqual(wrongModels.polish, .modelNotFound("grok-nope"))
        print("live key test:", good.speech.summary, "/", good.polish.summary)
    }
}
