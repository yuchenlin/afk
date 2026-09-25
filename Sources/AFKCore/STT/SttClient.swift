import Foundation

public protocol SttClient: Sendable {
    func transcribeStreaming(
        pcm16k: AsyncStream<Data>,
        keyTerms: [String]
    ) -> AsyncStream<TranscriptEvent>
}

/// Default cloud engine: Grok Voice Transcribe 2.0 over WebSocket.
/// Network implementation is stubbed until API key + proxy are wired.
public struct GrokSttClient: SttClient {
    public var model: String
    public var endpoint: URL
    public var apiKeyProvider: @Sendable () -> String?

    public init(
        model: String = "grok-voice-transcribe-2.0",
        endpoint: URL = URL(string: "wss://api.x.ai/v1/stt")!,
        apiKeyProvider: @escaping @Sendable () -> String? = { ProcessInfo.processInfo.environment["XAI_API_KEY"] }
    ) {
        self.model = model
        self.endpoint = endpoint
        self.apiKeyProvider = apiKeyProvider
    }

    public func transcribeStreaming(
        pcm16k: AsyncStream<Data>,
        keyTerms: [String]
    ) -> AsyncStream<TranscriptEvent> {
        AsyncStream { continuation in
            Task {
                guard apiKeyProvider() != nil else {
                    continuation.yield(.error("XAI_API_KEY not set — configure via proxy or env for local dev"))
                    continuation.finish()
                    return
                }
                // Drain audio so callers can exercise the pipeline; real WS framing comes next.
                for await _ in pcm16k { }
                let terms = Array(keyTerms.prefix(100))
                continuation.yield(.partial("(streaming stub)"))
                continuation.yield(.final("(final stub — wire Grok WS; keyTerms=\(terms.count))"))
                continuation.finish()
            }
        }
    }
}

/// Backup provider slot (DashScope Fun-ASR / local sherpa later).
public struct FunAsrSttClient: SttClient {
    public init() {}

    public func transcribeStreaming(
        pcm16k: AsyncStream<Data>,
        keyTerms: [String]
    ) -> AsyncStream<TranscriptEvent> {
        AsyncStream { continuation in
            Task {
                for await _ in pcm16k { }
                continuation.yield(.error("Fun-ASR provider not wired yet"))
                continuation.finish()
            }
        }
    }
}

public enum SttProvider: String, Sendable, CaseIterable {
    case grok
    case funAsr
}
