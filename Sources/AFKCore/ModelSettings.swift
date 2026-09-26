import Foundation

/// Model names, overridable from Settings → Advanced (stored in UserDefaults).
public enum ModelSettings {
    public static let defaultSpeechModel = Provider.xai.defaultModel(for: .speech)
    public static var defaultPolishModel: String { Provider.xai.defaultModel(for: .polish) }

    public static func speechModel(_ defaults: UserDefaults = .standard) -> String {
        ProviderSettings.model(for: .speech, provider: .xai, defaults)
    }

    public static func polishModel(_ defaults: UserDefaults = .standard) -> String {
        ProviderSettings.model(for: .polish, provider: .xai, defaults)
    }

    /// Empty or default values clear the override so future default changes apply.
    public static func save(speech: String, polish: String, to defaults: UserDefaults = .standard) {
        ProviderSettings.setModel(speech, for: .speech, provider: .xai, defaults)
        ProviderSettings.setModel(polish, for: .polish, provider: .xai, defaults)
    }
}

/// Outcome of probing one endpoint with a key.
public enum KeyCheck: Equatable, Sendable {
    case ok(seconds: Double)
    case invalidKey
    case noAccess(String)
    case modelNotFound(String)
    case failed(String)

    public var isOK: Bool { if case .ok = self { return true } else { return false } }

    public var summary: String {
        switch self {
        case let .ok(seconds): return String(format: "OK (%.1f s)", seconds)
        case .invalidKey: return "Incorrect API key"
        case let .noAccess(message): return "No access — \(message)"
        case let .modelNotFound(model): return "Model “\(model)” not found or not available to this key"
        case let .failed(message): return message
        }
    }

    /// Maps an HTTP result to a check. xAI answers 400 "Incorrect API key" for bad keys,
    /// 403 for keys without permission (e.g. no chat access or blocked), 404 for unknown models.
    public static func from(status: Int, body: Data, model: String, seconds: Double) -> KeyCheck {
        let message = APIErrorBody.message(from: body)
        let lower = message.lowercased()
        switch status {
        case 200:
            return .ok(seconds: seconds)
        case 401:
            return .invalidKey
        case 400 where lower.contains("api key"):
            return .invalidKey
        case 400 where lower.contains("not a valid model"), 404 where !lower.contains("data policy"):
            return .modelNotFound(model)
        case 403:
            return .noAccess(message)
        case 404:
            // OpenRouter: every provider for this model is excluded by the account's privacy settings.
            return .noAccess("blocked by your OpenRouter privacy / data policy settings (openrouter.ai/settings/privacy)")
        default:
            return .failed("HTTP \(status): \(message)")
        }
    }

    /// Network errors, with a hint for local servers that aren't running.
    public static func from(error: Error, endpoint: Endpoint) -> KeyCheck {
        if let urlError = error as? URLError, [.cannotConnectToHost, .cannotFindHost].contains(urlError.code) {
            return .failed("Can't reach \(endpoint.baseURL) — is the server running?")
        }
        return .failed(error.localizedDescription)
    }
}

/// Probes the speech and polish endpoints AFK is configured to use, so problems show up
/// in Settings instead of mid-dictation.
public enum ApiKeyTester {
    public struct Result: Equatable, Sendable {
        public var speech: KeyCheck
        public var polish: KeyCheck
    }

    /// xAI for both stages with one key (kept for older callers and tests).
    public static func test(
        key: String,
        speechModel: String,
        polishModel: String,
        urlSession: URLSession = .shared,
        completion: @escaping @MainActor @Sendable (Result) -> Void
    ) {
        test(speech: Endpoint(provider: .xai, apiKey: key, model: speechModel),
             polish: Endpoint(provider: .xai, apiKey: key, model: polishModel),
             urlSession: urlSession, completion: completion)
    }

    public static func test(
        speech: Endpoint,
        polish: Endpoint,
        urlSession: URLSession = .shared,
        completion: @escaping @MainActor @Sendable (Result) -> Void
    ) {
        let results = ResultBox()
        let group = DispatchGroup()

        // 0.5 s of silence: the cheapest request that exercises auth, permission, and model.
        let silence = Data(count: AudioRecorder.sampleRate)
        let speechRequest: URLRequest?
        if speech.provider == .xai {
            var config = GrokSttConfig(apiKey: speech.apiKey ?? "")
            config.model = speech.model
            speechRequest = GrokBatchStt.request(pcm: silence, config: config)
        } else {
            speechRequest = OpenAITranscriber.request(pcm: silence, endpoint: speech, vocabulary: [])
        }
        group.enter()
        run(speechRequest, endpoint: speech, urlSession: urlSession) { check in
            results.set(speech: check)
            group.leave()
        }

        // Local models may need to load into memory on the first request.
        let timeout: TimeInterval = polish.provider.hasEditableBaseURL ? 90 : 20
        let polishRequest = Polisher.chatRequest(endpoint: polish, messages: [["role": "user", "content": "Reply with: ok"]],
                                                 maxTokens: 16, timeout: timeout)
        group.enter()
        run(polishRequest, endpoint: polish, urlSession: urlSession) { check in
            results.set(polish: check)
            group.leave()
        }

        group.notify(queue: .global()) {
            let result = results.result
            Task { @MainActor in completion(result) }
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var speech = KeyCheck.failed("not run")
        private var polish = KeyCheck.failed("not run")

        func set(speech check: KeyCheck) { lock.lock(); speech = check; lock.unlock() }
        func set(polish check: KeyCheck) { lock.lock(); polish = check; lock.unlock() }
        var result: Result { lock.lock(); defer { lock.unlock() }; return Result(speech: speech, polish: polish) }
    }

    private static func run(
        _ request: URLRequest?,
        endpoint: Endpoint,
        urlSession: URLSession,
        done: @escaping @Sendable (KeyCheck) -> Void
    ) {
        guard let request, request.url?.scheme?.hasPrefix("http") == true else {
            return done(.failed("Invalid server URL “\(endpoint.baseURL)”"))
        }
        let started = Date()
        urlSession.dataTask(with: request) { data, response, error in
            if let error { return done(KeyCheck.from(error: error, endpoint: endpoint)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done(KeyCheck.from(status: status, body: data ?? Data(), model: endpoint.model, seconds: Date().timeIntervalSince(started)))
        }.resume()
    }
}
