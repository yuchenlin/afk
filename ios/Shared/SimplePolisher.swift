import Foundation

/// Lightweight cloud polish via OpenAI-compatible chat — same default model as Mac.
/// Full Mac `Polisher` / vocabulary wiring lands with AFKKit extraction.
public final class SimplePolisher: TextPolishing, @unchecked Sendable {
    public var baseURL = "https://api.x.ai/v1"
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func polish(_ text: String, model: String, apiKey: String?) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard let apiKey, !apiKey.isEmpty else { throw SpeechPipelineError.noAPIKey }

        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let system = """
        You clean dictation. Remove fillers and false starts, keep the speaker's final intent, \
        fix punctuation, and preserve Chinese–English code-switching. Reply with ONLY the cleaned text.
        """
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": 512,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": trimmed],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpeechPipelineError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SpeechPipelineError.http(http.statusCode, String(decoding: data.prefix(400), as: UTF8.self))
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw SpeechPipelineError.badResponse }

        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? trimmed : cleaned
    }
}
