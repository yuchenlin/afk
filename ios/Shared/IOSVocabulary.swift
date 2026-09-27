import Foundation

/// Lightweight lexicon for iOS (mirrors Mac `LexiconStore` / `VocabularyStore`).
/// Stored in the App Group so host STT + polish share the same terms; seeded from the
/// Mac `Resources/lexicon.example.txt` defaults until a Settings editor ships.
public struct IOSLexicon: Sendable, Equatable {
    public static let maxKeyTerms = 100
    public static let maxTermLength = 50

    public var terms: [String]

    public init(terms: [String] = []) {
        self.terms = Self.normalize(terms)
    }

    public init(from text: String) {
        self.init(terms: text.split(whereSeparator: \.isNewline).map(String.init))
    }

    public var keyTermsForStt: [String] {
        Array(terms.filter { $0.count <= Self.maxTermLength }.prefix(Self.maxKeyTerms))
    }

    private static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in terms {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
}

public enum IOSVocabulary {
    public static let defaultsKey = "settings.vocabularyText"

    /// Same starter list as Mac `Resources/lexicon.example.txt`.
    public static let bundledDefaults = """
        # One term per line. Loaded as Grok STT key terms (max 100) + polish hints.
        # Lines starting with # are ignored.

        LoRA
        GRPO
        xAI
        Grok
        H1B
        Model Y
        CUDA
        Transformer
        Attention
        AFK
        """

    public static func loadText(from defaults: UserDefaults = SessionRelay.shared.defaults) -> String {
        if let saved = defaults.string(forKey: defaultsKey), !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return saved
        }
        return bundledDefaults
    }

    public static func load(from defaults: UserDefaults = SessionRelay.shared.defaults) -> IOSLexicon {
        IOSLexicon(from: loadText(from: defaults))
    }

    public static func save(_ text: String, to defaults: UserDefaults = SessionRelay.shared.defaults) {
        var contents = text
        if !contents.hasSuffix("\n") { contents += "\n" }
        defaults.set(contents, forKey: defaultsKey)
        defaults.synchronize()
    }
}
