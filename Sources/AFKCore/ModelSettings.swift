import Foundation

/// Model names, overridable from Settings → Advanced (stored in UserDefaults).
public enum ModelSettings {
    public static let defaultSpeechModel = "grok-voice-transcribe-2.0"
    public static var defaultPolishModel: String { PolishConfig.defaultModel }

    static let speechKey = "sttModel"
    static let polishKey = "polishModel"

    public static func speechModel(_ defaults: UserDefaults = .standard) -> String {
        nonEmpty(defaults.string(forKey: speechKey)) ?? defaultSpeechModel
    }

    public static func polishModel(_ defaults: UserDefaults = .standard) -> String {
        nonEmpty(defaults.string(forKey: polishKey)) ?? defaultPolishModel
    }

    /// Empty or default values clear the override so future default changes apply.
    public static func save(speech: String, polish: String, to defaults: UserDefaults = .standard) {
        store(speech, default: defaultSpeechModel, key: speechKey, defaults)
        store(polish, default: defaultPolishModel, key: polishKey, defaults)
    }

    private static func store(_ value: String, default def: String, key: String, _ defaults: UserDefaults) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty || v == def { defaults.removeObject(forKey: key) } else { defaults.set(v, forKey: key) }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
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
        struct ErrorBody: Decodable { let error: String? }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
            ?? String(decoding: body.prefix(200), as: UTF8.self)
        switch status {
        case 200: return .ok(seconds: seconds)
        case 400 where message.localizedCaseInsensitiveContains("api key"), 401: return .invalidKey
        case 403: return .noAccess(message)
        case 404: return .modelNotFound(model)
        default: return .failed("HTTP \(status): \(message)")
        }
    }
}

/// Probes both endpoints AFK uses, so key problems show up in Settings instead of mid-dictation.
public enum ApiKeyTester {
    public struct Result: Equatable, Sendable {
        public var speech: KeyCheck
        public var polish: KeyCheck
    }

    public static func test(
        key: String,
        speechModel: String,
        polishModel: String,
        urlSession: URLSession = .shared,
        completion: @escaping @MainActor @Sendable (Result) -> Void
    ) {
        let results = ResultBox()
        let group = DispatchGroup()

        var sttConfig = GrokSttConfig(apiKey: key)
        sttConfig.model = speechModel
        // 0.5 s of silence: cheapest request that exercises auth, permission, and model.
        let sttRequest = GrokBatchStt.request(pcm: Data(count: AudioRecorder.sampleRate), config: sttConfig)
        group.enter()
        run(sttRequest, model: speechModel, urlSession: urlSession) { check in
            results.set(speech: check)
            group.leave()
        }

        var chatRequest = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        chatRequest.httpMethod = "POST"
        chatRequest.timeoutInterval = 15
        chatRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        chatRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": polishModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]],
        ] as [String: Any])
        group.enter()
        run(chatRequest, model: polishModel, urlSession: urlSession) { check in
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
        _ request: URLRequest,
        model: String,
        urlSession: URLSession,
        done: @escaping @Sendable (KeyCheck) -> Void
    ) {
        let started = Date()
        urlSession.dataTask(with: request) { data, response, error in
            if let error { return done(.failed(error.localizedDescription)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done(KeyCheck.from(status: status, body: data ?? Data(), model: model, seconds: Date().timeIntervalSince(started)))
        }.resume()
    }
}
