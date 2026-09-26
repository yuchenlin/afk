import Foundation

/// Outcome of probing one xAI endpoint with a key (mirrors Mac `KeyCheck`).
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

    public static func from(status: Int, body: Data, model: String, seconds: Double) -> KeyCheck {
        let message = Self.message(from: body)
        let lower = message.lowercased()
        switch status {
        case 200: return .ok(seconds: seconds)
        case 401: return .invalidKey
        case 400 where lower.contains("api key"): return .invalidKey
        case 400 where lower.contains("not a valid model"), 404 where !lower.contains("data policy"):
            return .modelNotFound(model)
        case 403: return .noAccess(message.isEmpty ? "forbidden" : message)
        default: return .failed("HTTP \(status): \(message.isEmpty ? String(decoding: body.prefix(160), as: UTF8.self) : message)")
        }
    }

    public static func from(error: Error) -> KeyCheck {
        if let urlError = error as? URLError, [.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .timedOut].contains(urlError.code) {
            return .failed("Network: \(urlError.localizedDescription)")
        }
        return .failed(error.localizedDescription)
    }

    private static func message(from body: Data) -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return String(decoding: body.prefix(200), as: UTF8.self) }
        if let err = obj["error"] as? [String: Any] {
            if let m = err["message"] as? String { return m }
            if let m = err["error"] as? String { return m }
        }
        if let m = obj["message"] as? String { return m }
        return String(decoding: body.prefix(200), as: UTF8.self)
    }
}

/// Probes speech (batch STT) + polish (chat) so Settings can surface auth/model problems.
public enum ApiKeyTester {
    public struct Result: Equatable, Sendable {
        public var speech: KeyCheck
        public var polish: KeyCheck
        public var keychainReadable: Bool
    }

    public static func test(
        key: String,
        speechModel: String,
        polishModel: String,
        urlSession: URLSession = .shared
    ) async -> Result {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(speech: .failed("No API key"), polish: .failed("No API key"), keychainReadable: KeychainStore.readAPIKey() != nil)
        }

        async let speech = probeSpeech(key: trimmed, model: speechModel, urlSession: urlSession)
        async let polish = probePolish(key: trimmed, model: polishModel, urlSession: urlSession)
        let (s, p) = await (speech, polish)
        return Result(speech: s, polish: p, keychainReadable: KeychainStore.readAPIKey() != nil)
    }

    private static func probeSpeech(key: String, model: String, urlSession: URLSession) async -> KeyCheck {
        // 0.5 s of silence PCM16 @ 16 kHz (Mac uses Data(count: sampleRate) = 16000 bytes).
        let pcm = Data(count: PCMWav.defaultSampleRate)
        let boundary = "afk-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/stt")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("audio_format", "pcm")
        field("sample_rate", String(PCMWav.defaultSampleRate))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.pcm\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(pcm)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let started = Date()
        do {
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return KeyCheck.from(status: status, body: data, model: model, seconds: Date().timeIntervalSince(started))
        } catch {
            return KeyCheck.from(error: error)
        }
    }

    private static func probePolish(key: String, model: String, urlSession: URLSession) async -> KeyCheck {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": 16,
            "messages": [["role": "user", "content": "Reply with: ok"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let started = Date()
        do {
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return KeyCheck.from(status: status, body: data, model: model, seconds: Date().timeIntervalSince(started))
        } catch {
            return KeyCheck.from(error: error)
        }
    }
}
