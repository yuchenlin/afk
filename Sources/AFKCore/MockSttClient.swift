import Foundation

/// Offline stand-in until Grok / Fun-ASR is wired. Proves Fn → insert path.
public struct MockSttClient: Sendable {
    public init() {}

    public func transcribe(holdDuration: TimeInterval) -> String {
        let ms = Int((holdDuration * 1000).rounded())
        return "AFK OK (\(ms)ms) — Fn hold works. STT API next."
    }
}
