import Foundation

public struct LexiconStore: Sendable, Equatable {
    public var terms: [String]

    public init(terms: [String] = []) {
        self.terms = Self.normalize(terms)
    }

    public init(from text: String) {
        self.init(terms: text.split(whereSeparator: \.isNewline).map(String.init))
    }

    public var keyTermsForStt: [String] { Array(terms.prefix(100)) }

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
