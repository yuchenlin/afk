import Foundation

/// Pluggable STT for the iOS host. Real Grok client or mock for simulator / offline use.
public protocol SpeechTranscribing: AnyObject {
    func transcribe(pcm16: Data, sampleRate: Int, model: String, apiKey: String?) async throws -> String
}

public protocol TextPolishing: AnyObject {
    func polish(_ text: String, model: String, apiKey: String?) async throws -> String
}

public enum SpeechPipelineError: LocalizedError {
    case noAPIKey
    case emptyAudio
    case http(Int, String)
    case badResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Add an xAI API key in Settings to use live STT (or enable Mock STT for offline)."
        case .emptyAudio: return "Recording was too short."
        case let .http(code, body): return "HTTP \(code): \(body.prefix(200))"
        case .badResponse: return "Unexpected API response"
        case .cancelled: return "Cancelled"
        }
    }
}
