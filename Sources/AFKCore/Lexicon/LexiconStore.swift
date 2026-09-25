import Foundation

public struct LexiconStore: Sendable, Equatable {
    public var terms: [String]

    public init(terms: [String] = []) {
        self.terms = Self.normalize(terms)
    }

    public init(from text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        self.init(terms: lines)
    }

    public static func load(from url: URL) throws -> LexiconStore {
        let text = try String(contentsOf: url, encoding: .utf8)
        return LexiconStore(from: text)
    }

    /// Grok accepts at most 100 key terms.
    public var keyTermsForStt: [String] {
        Array(terms.prefix(100))
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
