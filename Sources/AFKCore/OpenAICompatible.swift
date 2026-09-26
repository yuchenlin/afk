import Foundation

/// One push-to-talk utterance, whichever provider transcribes it.
public protocol SpeechSession: AnyObject {
    /// Live transcript while recording (streaming providers only), on the main queue.
    var onPartial: (@MainActor @Sendable (String) -> Void)? { get set }
    func start()
    func append(_ chunk: Data)
    func finish(timeout: TimeInterval, completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void)
    func cancel()
}

extension GrokSttSession: SpeechSession {}

/// Error text from either response shape: xAI's `{"error": "…"}` or the OpenAI /
/// OpenRouter / Ollama `{"error": {"message": "…"}}`.
public enum APIErrorBody {
    public static func message(from body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let text = object["error"] as? String { return text }
            if let nested = object["error"] as? [String: Any], let text = nested["message"] as? String { return text }
            if let text = object["message"] as? String { return text }
        }
        return String(decoding: body.prefix(200), as: UTF8.self)
    }
}

/// `POST {base}/audio/transcriptions` (OpenAI format), used for OpenRouter, OpenAI, and
/// local OpenAI-compatible servers. Not streaming: the whole recording is sent at the end.
public enum OpenAITranscriber {
    /// Whisper-style prompts are capped at ~224 tokens; a short term list fits comfortably.
    static let maxPromptTerms = 40

    public static func request(pcm: Data, endpoint: Endpoint, vocabulary: [String]) -> URLRequest? {
        guard let url = endpoint.url("/audio/transcriptions") else { return nil }
        let boundary = "afk-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        endpoint.authorize(&request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var fields = [("model", endpoint.model), ("response_format", "json")]
        let terms = vocabulary.prefix(maxPromptTerms)
        if !terms.isEmpty { fields.append(("prompt", terms.joined(separator: ", "))) }

        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav(pcm16: pcm, sampleRate: AudioRecorder.sampleRate))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    public static func transcribe(
        pcm: Data,
        endpoint: Endpoint,
        vocabulary: [String],
        urlSession: URLSession = .shared,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) -> URLSessionDataTask? {
        guard let request = request(pcm: pcm, endpoint: endpoint, vocabulary: vocabulary) else {
            completion(.failure(URLError(.badURL)))
            return nil
        }
        let task = urlSession.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data ?? Data()
            guard status == 200 else {
                return completion(.failure(GrokSttError.http(status, String(decoding: body, as: UTF8.self))))
            }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let text = object["text"] as? String
            else { return completion(.failure(GrokSttError.badResponse)) }
            completion(.success(cleanTranscript(text)))
        }
        task.resume()
        return task
    }

    /// Normalizes transcripts from Whisper-family models: drops non-speech tags such as
    /// "[BLANK_AUDIO]" or "(music)", and converts Traditional Chinese to Simplified (small
    /// Whisper models often answer Mandarin in Traditional characters).
    public static func cleanTranscript(_ text: String) -> String {
        // Tags are all caps ("[BLANK_AUDIO]", "[NOISE]"); ordinary bracketed words are kept.
        var s = text.replacingOccurrences(of: #"\[[A-Z][A-Z_ ]*\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\((?:music|silence|noise|inaudible)\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        if s.unicodeScalars.contains(where: Polisher.isCJK),
           let simplified = s.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) {
            s = simplified
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wraps mono PCM16 in a minimal WAV (RIFF) header.
    public static func wav(pcm16 pcm: Data, sampleRate: Int) -> Data {
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8)
        d += le32(36 + pcm.count) + Data("WAVE".utf8)
        d += Data("fmt ".utf8) + le32(16) + le16(1) + le16(1)  // PCM, mono
        d += le32(sampleRate) + le32(sampleRate * 2) + le16(2) + le16(16)
        d += Data("data".utf8) + le32(pcm.count) + pcm
        return d
    }
}

/// Records the whole utterance, then transcribes it in one request when it ends.
public final class BatchSpeechSession: SpeechSession, @unchecked Sendable {
    public var onPartial: (@MainActor @Sendable (String) -> Void)?

    private let endpoint: Endpoint
    private let vocabulary: [String]
    private let urlSession: URLSession
    private let queue = DispatchQueue(label: "xyz.yuchenlin.afk.batch-stt")
    private var audio = Data()
    private var cancelled = false
    private var task: URLSessionDataTask?

    public init(endpoint: Endpoint, vocabulary: [String], urlSession: URLSession = .shared) {
        self.endpoint = endpoint
        self.vocabulary = vocabulary
        self.urlSession = urlSession
    }

    public func start() {
        sttLog.info("batch: recording for \(self.endpoint.provider.displayName, privacy: .public) \(self.endpoint.model, privacy: .public)")
    }

    public func append(_ chunk: Data) {
        queue.async { if !self.cancelled { self.audio.append(chunk) } }
    }

    /// `timeout` is unused: the request has its own timeout and the app has a watchdog.
    public func finish(timeout: TimeInterval, completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void) {
        queue.async {
            guard !self.cancelled else { return }
            let pcm = self.audio
            // Under ~0.2 s of audio there's nothing worth sending.
            guard pcm.count > AudioRecorder.sampleRate * 2 / 5 else {
                DispatchQueue.main.async { completion(.success("")) }
                return
            }
            let started = Date()
            // The task's handler retains self until the result is delivered.
            self.task = OpenAITranscriber.transcribe(pcm: pcm, endpoint: self.endpoint, vocabulary: self.vocabulary, urlSession: self.urlSession) { result in
                let seconds = Date().timeIntervalSince(started)
                self.queue.async {
                    guard !self.cancelled else { return }
                    switch result {
                    case let .success(text): sttLog.info("batch: \(text.count) chars in \(seconds, privacy: .public)s")
                    case let .failure(error): sttLog.error("batch failed: \(error.localizedDescription, privacy: .public)")
                    }
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
    }

    public func cancel() {
        queue.async {
            self.cancelled = true
            self.task?.cancel()
        }
    }
}
