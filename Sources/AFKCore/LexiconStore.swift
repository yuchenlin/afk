import Foundation

public struct LexiconStore: Sendable, Equatable {
    /// xAI STT limits: at most 100 key terms per request, each up to 50 characters.
    public static let maxKeyTerms = 100
    public static let maxTermLength = 50

    public var terms: [String]

    public init(terms: [String] = []) {
        self.terms = Self.normalize(terms)
    }

    public init(from text: String) {
        self.init(terms: text.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// Terms the API rejects for length; these are left out of requests.
    public var tooLongTerms: [String] { terms.filter { $0.count > Self.maxTermLength } }

    public var keyTermsForStt: [String] {
        Array(terms.filter { $0.count <= Self.maxTermLength }.prefix(Self.maxKeyTerms))
    }

    /// Valid terms beyond the per-request limit, which are not sent.
    public var overLimitCount: Int {
        max(0, terms.count - tooLongTerms.count - Self.maxKeyTerms)
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

/// The user's vocabulary file, falling back to the bundled example list.
public enum VocabularyStore {
    public static var userFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AFK/lexicon.txt")
    }

    public static var bundledText: String? {
        Bundle.main.url(forResource: "lexicon", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The editable text: the user's file if it exists, else the bundled examples.
    public static func loadText(fileURL: URL = userFileURL) -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? bundledText ?? ""
    }

    public static func load(fileURL: URL = userFileURL) -> LexiconStore {
        LexiconStore(from: loadText(fileURL: fileURL))
    }

    public static func save(_ text: String, to fileURL: URL = userFileURL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var contents = text
        if !contents.hasSuffix("\n") { contents += "\n" }
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
