import Foundation

/// Batch `POST https://api.x.ai/v1/stt` with raw PCM16 — mirrors Mac `GrokBatchStt`.
/// Streaming WebSocket reuse of AFKCore is deferred until AFKKit extraction (Phase 0).
public final class GrokBatchSpeechClient: SpeechTranscribing, @unchecked Sendable {
    public var host = "api.x.ai"
    /// STT keyterms (≤100, each ≤50 chars) — same field Mac sends on batch + stream.
    public var keyterms: [String] = []
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func transcribe(pcm16: Data, sampleRate: Int, model: String, apiKey: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw SpeechPipelineError.noAPIKey }
        // ~0.2 s minimum (Mac uses the same threshold)
        guard pcm16.count > sampleRate * 2 / 5 else { throw SpeechPipelineError.emptyAudio }

        let terms = Array(keyterms.filter { $0.count <= 50 }.prefix(100))
        let boundary = "afk-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://\(host)/v1/stt")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("audio_format", "pcm")
        field("sample_rate", String(sampleRate))
        for term in terms {
            field("keyterm", term)
        }
        // API requires `file` to be the last field (same as Mac GrokBatchStt).
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.pcm\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(pcm16)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SpeechPipelineError.http(-1, "Network: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw SpeechPipelineError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SpeechPipelineError.http(http.statusCode, String(decoding: data.prefix(400), as: UTF8.self))
        }
        struct Response: Decodable { let text: String }
        if let parsed = try? JSONDecoder().decode(Response.self, from: data) {
            return parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw SpeechPipelineError.badResponse
    }
}
