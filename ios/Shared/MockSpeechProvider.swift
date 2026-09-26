import Foundation

/// Offline stand-in so the host → App Group → keyboard path works without keys.
public final class MockSpeechProvider: SpeechTranscribing, TextPolishing, @unchecked Sendable {
    public init() {}

    public func transcribe(pcm16: Data, sampleRate: Int, model: String, apiKey: String?) async throws -> String {
        // Never emit the mock transcript when a real key is available — caller should use Grok.
        if let apiKey, !apiKey.isEmpty {
            throw SpeechPipelineError.http(-1, "Mock STT blocked: API key is saved; use live Grok STT.")
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let seconds = Double(pcm16.count) / Double(max(sampleRate, 1) * 2)
        return String(
            format: "[mock STT · %.1fs · %@] Hello from AFK iOS — offline mock (enable only without an API key).",
            seconds,
            model
        )
    }

    public func polish(_ text: String, model: String, apiKey: String?) async throws -> String {
        try await Task.sleep(nanoseconds: 150_000_000)
        // Light cleanup matching Mac polish intent (no LLM).
        var t = text
        for filler in ["那个那个", "嗯+", "啊+", "那个"] {
            t = t.replacingOccurrences(of: filler, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
