import Foundation
import os

let sttLog = Logger(subsystem: "xyz.yuchenlin.afk", category: "stt")

public struct GrokSttConfig: Sendable {
    public var apiKey: String
    public var keyterms: [String]
    public var model = "grok-voice-transcribe-2.0"
    public var sampleRate = AudioRecorder.sampleRate
    /// Host serving `/v1/stt`; overridable for tests.
    public var host = "api.x.ai"

    public init(apiKey: String, keyterms: [String] = []) {
        self.apiKey = apiKey
        self.keyterms = Array(keyterms.filter { $0.count <= 50 }.prefix(100))
    }
}

public enum GrokSttError: LocalizedError {
    case server(String)
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case let .server(message): return message
        case let .http(code, body):
            struct Body: Decodable { let error: String }
            if let parsed = try? JSONDecoder().decode(Body.self, from: Data(body.utf8)) {
                return parsed.error
            }
            return "HTTP \(code): \(body.prefix(200))"
        case .badResponse: return "Unexpected response from xAI"
        }
    }
}

/// One push-to-talk utterance streamed to `wss://api.x.ai/v1/stt`.
/// Audio sent before the server is ready is buffered; the full recording is kept so
/// `finish` can fall back to the batch endpoint if the stream fails or stalls.
public final class GrokSttSession: @unchecked Sendable {
    /// Live transcript text, delivered on the main queue.
    public var onPartial: (@MainActor @Sendable (String) -> Void)?

    private let config: GrokSttConfig
    private let queue = DispatchQueue(label: "xyz.yuchenlin.afk.stt")
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?

    // All state below is confined to `queue`.
    private var ready = false
    private var streamFailed = false
    private var pending: [Data] = []
    private var recording = Data()
    private var assembler = TranscriptAssembler()
    private var finishRequested = false
    private var completed = false
    private var completion: (@MainActor @Sendable (Result<String, Error>) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    /// Keeps the session alive from `finish` until the result is delivered, since
    /// callers typically drop their reference right after asking for the result.
    private var keepAlive: GrokSttSession?
    private var bytesSent = 0
    private var partialCount = 0
    private let startedAt = Date()

    private var elapsed: String { String(format: "%.2fs", Date().timeIntervalSince(startedAt)) }

    public init(config: GrokSttConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    public static func streamingURL(for config: GrokSttConfig) -> URL {
        var components = URLComponents(string: "wss://\(config.host)/v1/stt")!
        var items = [
            URLQueryItem(name: "model", value: config.model),
            URLQueryItem(name: "sample_rate", value: String(config.sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: "true"),
        ]
        items += config.keyterms.map { URLQueryItem(name: "keyterm", value: $0) }
        components.queryItems = items
        return components.url!
    }

    public func start() {
        var request = URLRequest(url: Self.streamingURL(for: config))
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: request)
        sttLog.info("stream: connecting (\(self.config.keyterms.count) keyterms)")
        queue.async {
            self.task = task
            task.resume()
            self.receive()
        }
    }

    public func append(_ chunk: Data) {
        queue.async {
            guard !self.completed else { return }
            self.recording.append(chunk)
            if self.ready && !self.streamFailed {
                self.bytesSent += chunk.count
                self.task?.send(.data(chunk)) { _ in }
            } else if !self.streamFailed {
                self.pending.append(chunk)
            }
        }
    }

    /// Ends the utterance. `completion` runs on the main queue with the final transcript.
    public func finish(
        timeout: TimeInterval = 4,
        completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void
    ) {
        queue.async {
            guard !self.completed else { return }
            self.completion = completion
            self.finishRequested = true
            self.keepAlive = self
            sttLog.info("finish at \(self.elapsed, privacy: .public): recorded \(self.recording.count) bytes, sent \(self.bytesSent), ready=\(self.ready), failed=\(self.streamFailed)")
            if self.streamFailed {
                self.fallBackToBatch()
                return
            }
            if self.ready { self.sendAudioDone() }
            let work = DispatchWorkItem { [weak self] in self?.fallBackToBatch() }
            self.timeoutWork = work
            self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    /// Abandons the utterance without a result (e.g. the hold was only a tap).
    public func cancel() {
        queue.async {
            self.completed = true
            self.timeoutWork?.cancel()
            self.timeoutWork = nil
            self.completion = nil
            self.keepAlive = nil
            self.task?.cancel(with: .normalClosure, reason: nil)
        }
    }

    // MARK: - Streaming

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case let .success(.string(text)):
                    self.handle(Data(text.utf8))
                    self.receive()
                case let .success(.data(data)):
                    self.handle(data)
                    self.receive()
                case let .failure(error):
                    self.failStream(error)
                @unknown default:
                    self.receive()
                }
            }
        }
    }

    private struct Event: Decodable {
        let type: String
        let text: String?
        let is_final: Bool?
        let speech_final: Bool?
        let message: String?
    }

    private func handle(_ data: Data) {
        guard !completed, let event = try? JSONDecoder().decode(Event.self, from: data) else { return }
        switch event.type {
        case "transcript.created":
            ready = true
            sttLog.info("stream: ready at \(self.elapsed, privacy: .public), flushing \(self.pending.count) buffered chunks")
            for chunk in pending {
                bytesSent += chunk.count
                task?.send(.data(chunk)) { _ in }
            }
            pending.removeAll()
            if finishRequested { sendAudioDone() }
        case "transcript.partial":
            assembler.apply(
                text: event.text ?? "",
                isFinal: event.is_final ?? false,
                speechFinal: event.speech_final ?? false
            )
            let text = assembler.text
            partialCount += 1
            let onPartial = self.onPartial
            DispatchQueue.main.async { onPartial?(text) }
        case "transcript.done":
            let final = (event.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            sttLog.info("stream: done at \(self.elapsed, privacy: .public) after \(self.partialCount) partials, \(final.count) chars")
            complete(.success(final.isEmpty ? assembler.text : final))
            task?.cancel(with: .normalClosure, reason: nil)
        case "error":
            failStream(GrokSttError.server(event.message ?? "Streaming error"))
        default:
            break
        }
    }

    private func sendAudioDone() {
        task?.send(.string(#"{"type":"audio.done"}"#)) { _ in }
    }

    private func failStream(_ error: Error) {
        guard !completed, !streamFailed else { return }
        streamFailed = true
        sttLog.error("stream failed at \(self.elapsed, privacy: .public): \(error.localizedDescription, privacy: .public)")
        pending.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        if finishRequested { fallBackToBatch() }
    }

    // MARK: - Batch fallback

    private func fallBackToBatch() {
        guard !completed else { return }
        timeoutWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        sttLog.info("falling back to batch at \(self.elapsed, privacy: .public) (\(self.recording.count) bytes)")
        let streamed = assembler.text
        let audio = recording
        // Under ~0.2 s of audio there's nothing worth sending.
        guard audio.count > config.sampleRate * 2 / 5 else {
            complete(.success(streamed))
            return
        }
        GrokBatchStt.transcribe(pcm: audio, config: config, urlSession: urlSession) { result in
            self.queue.async {
                switch result {
                case .success:
                    self.complete(result)
                case .failure where !streamed.isEmpty:
                    self.complete(.success(streamed))
                case .failure:
                    self.complete(result)
                }
            }
        }
    }

    private func complete(_ result: Result<String, Error>) {
        guard !completed else { return }
        completed = true
        timeoutWork?.cancel()
        timeoutWork = nil
        let completion = self.completion
        self.completion = nil
        keepAlive = nil
        switch result {
        case let .success(text): sttLog.info("result at \(self.elapsed, privacy: .public): \(text.count) chars")
        case let .failure(error): sttLog.error("result at \(self.elapsed, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        DispatchQueue.main.async { completion?(result) }
    }
}

/// `POST https://api.x.ai/v1/stt` with raw PCM16.
public enum GrokBatchStt {
    public static func request(pcm: Data, config: GrokSttConfig) -> URLRequest {
        let boundary = "afk-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://\(config.host)/v1/stt")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var fields: [(String, String)] = [
            ("model", config.model),
            ("audio_format", "pcm"),
            ("sample_rate", String(config.sampleRate)),
        ]
        fields += config.keyterms.map { ("keyterm", $0) }

        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        // The API requires `file` to be the last field.
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.pcm\"\r\n")
        body.append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(pcm)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    public static func transcribe(
        pcm: Data,
        config: GrokSttConfig,
        urlSession: URLSession = .shared,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        urlSession.dataTask(with: request(pcm: pcm, config: config)) { data, response, error in
            if let error { return completion(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data ?? Data()
            guard status == 200 else {
                return completion(.failure(GrokSttError.http(status, String(decoding: body, as: UTF8.self))))
            }
            struct Response: Decodable { let text: String }
            guard let parsed = try? JSONDecoder().decode(Response.self, from: body) else {
                return completion(.failure(GrokSttError.badResponse))
            }
            completion(.success(parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.resume()
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
