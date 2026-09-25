import Foundation

/// End-to-end hold-to-talk session orchestration.
public actor DictationPipeline {
    private let audio: AudioCapturing
    private let stt: any SttClient
    private let polish: any Polishing
    private let inserter: any TextInserting
    private var lexicon: LexiconStore

    public init(
        audio: AudioCapturing,
        stt: any SttClient,
        polish: any Polishing = PolishClient(),
        inserter: any TextInserting,
        lexicon: LexiconStore = LexiconStore()
    ) {
        self.audio = audio
        self.stt = stt
        self.polish = polish
        self.inserter = inserter
        self.lexicon = lexicon
    }

    public func updateLexicon(_ store: LexiconStore) {
        lexicon = store
    }

    public func beginHold() throws {
        try audio.start()
    }

    /// Stops capture, runs STT+polish, inserts. Yields transcript events for UI.
    public func endHold() -> AsyncStream<TranscriptEvent> {
        AsyncStream { continuation in
            Task {
                let pcm = self.audio.stop()
                let (stream, writer) = AsyncStream.makeStream(of: Data.self)
                writer.yield(pcm)
                writer.finish()

                var lastFinal: String?
                for await event in self.stt.transcribeStreaming(pcm16k: stream, keyTerms: self.lexicon.keyTermsForStt) {
                    continuation.yield(event)
                    if case .final(let t) = event { lastFinal = t }
                    if case .error = event {
                        continuation.finish()
                        return
                    }
                }

                guard let raw = lastFinal else {
                    continuation.yield(.error("No final transcript"))
                    continuation.finish()
                    return
                }

                do {
                    let cleaned = try await self.polish.polish(PolishRequest(raw: raw, lexicon: self.lexicon.terms))
                    try self.inserter.insert(cleaned)
                    continuation.yield(.final(cleaned))
                } catch {
                    continuation.yield(.error(String(describing: error)))
                }
                continuation.finish()
            }
        }
    }
}
