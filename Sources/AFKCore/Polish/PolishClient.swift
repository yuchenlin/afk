import Foundation

public protocol Polishing: Sendable {
    func polish(_ request: PolishRequest) async throws -> String
}

/// Cheap second-stage cleanup. Real LLM call TBD; rule pass ships now.
public struct PolishClient: Polishing {
    public init() {}

    public func polish(_ request: PolishRequest) async throws -> String {
        var text = request.raw
        let fillers = ["那个那个", "那个", "嗯", "啊", "um", "uh", "Uh", "Um"]
        for f in fillers {
            text = text.replacingOccurrences(of: f, with: "")
        }
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Simple case-preserving lexicon reinforce (exact / ignore-case contains → canonical).
        for term in request.lexicon {
            let pattern = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: term), options: [.caseInsensitive])
            guard let pattern else { continue }
            let range = NSRange(text.startIndex..., in: text)
            text = pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: term)
        }
        return text
    }
}

public enum PolishPrompt {
    /// Keep tiny — only one utterance.
    public static let system = """
    You clean a single speech-to-text line for typing into an app.
    Remove fillers and false starts; keep the speaker's final intent after self-corrections.
    Preserve Chinese–English mix; fix spacing/punctuation so it looks typed.
    Prefer lexicon spellings when provided. Output only the cleaned line.
    """
}
