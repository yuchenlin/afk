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
///
/// Cross-device sync (Mac ↔ iOS) uses iCloud Key-Value Store:
/// - Keys: `afk.vocabularyText` + `afk.vocabularyUpdatedAt`
/// - Shared KVS id (entitlements): `$(TeamIdentifierPrefix)xyz.yuchenlin.afk`
/// - Merge: **last-writer-wins on the whole text** (compare `afk.vocabularyUpdatedAt`).
/// - If the user is not signed into iCloud, AFK stays local-only (no errors).
public enum VocabularyStore {
    public static let iCloudTextKey = "afk.vocabularyText"
    public static let iCloudUpdatedAtKey = "afk.vocabularyUpdatedAt"
    public static let localUpdatedAtDefaultsKey = "afk.vocabularyUpdatedAt.local"

    public static var userFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AFK/lexicon.txt")
    }

    public static var bundledText: String? {
        Bundle.main.url(forResource: "lexicon", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// True when an iCloud account is available for KVS (graceful local-only otherwise).
    public static var isiCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// The editable text: the user's file if it exists, else the bundled examples.
    public static func loadText(fileURL: URL = userFileURL) -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? bundledText ?? ""
    }

    public static func load(fileURL: URL = userFileURL) -> LexiconStore {
        LexiconStore(from: loadText(fileURL: fileURL))
    }

    /// Writes local Application Support and pushes to iCloud KVS when available.
    public static func save(_ text: String, to fileURL: URL = userFileURL) throws {
        var contents = text
        if !contents.hasSuffix("\n") { contents += "\n" }
        let now = Date().timeIntervalSince1970
        try writeLocal(contents, to: fileURL, updatedAt: now)
        pushToiCloud(contents, updatedAt: now)
    }

    /// Pull remote if newer (or seed empty KVS from local). Returns whether the local file changed.
    @discardableResult
    public static func pullFromiCloudIfNewer(fileURL: URL = userFileURL) -> Bool {
        guard isiCloudAvailable else { return false }
        let store = NSUbiquitousKeyValueStore.default
        _ = store.synchronize()

        guard let remote = store.string(forKey: iCloudTextKey) else {
            seediCloudFromLocalIfNeeded(fileURL: fileURL)
            return false
        }

        let remoteTs = store.object(forKey: iCloudUpdatedAtKey) as? Double ?? 0
        let localTs = localUpdatedAt(fileURL: fileURL)
        let remoteNormalized = normalizeTrailingNewline(remote)
        let localNormalized = normalizeTrailingNewline(
            (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        )

        if remoteTs > localTs || (localTs == 0 && !FileManager.default.fileExists(atPath: fileURL.path)) {
            if remoteNormalized != localNormalized || !FileManager.default.fileExists(atPath: fileURL.path) {
                let ts = remoteTs > 0 ? remoteTs : Date().timeIntervalSince1970
                try? writeLocal(remoteNormalized, to: fileURL, updatedAt: ts)
                return true
            }
            return false
        }

        if localTs > remoteTs, !localNormalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pushToiCloud(localNormalized, updatedAt: localTs)
        }
        return false
    }

    /// Observe remote KVS edits; callback on the main queue. Caller must retain the token
    /// (or remove the observer later).
    @discardableResult
    public static func observeExternalChanges(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            handler()
        }
    }

    // MARK: - Private

    private static func writeLocal(_ contents: String, to fileURL: URL, updatedAt: TimeInterval) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(updatedAt, forKey: localUpdatedAtDefaultsKey)
    }

    private static func pushToiCloud(_ text: String, updatedAt: TimeInterval = Date().timeIntervalSince1970) {
        guard isiCloudAvailable else { return }
        let store = NSUbiquitousKeyValueStore.default
        store.set(text, forKey: iCloudTextKey)
        store.set(updatedAt, forKey: iCloudUpdatedAtKey)
        _ = store.synchronize()
        UserDefaults.standard.set(updatedAt, forKey: localUpdatedAtDefaultsKey)
    }

    private static func seediCloudFromLocalIfNeeded(fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let local = try? String(contentsOf: fileURL, encoding: .utf8),
              !local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let ts = localUpdatedAt(fileURL: fileURL)
        pushToiCloud(normalizeTrailingNewline(local), updatedAt: ts > 0 ? ts : Date().timeIntervalSince1970)
    }

    private static func localUpdatedAt(fileURL: URL) -> TimeInterval {
        let stored = UserDefaults.standard.double(forKey: localUpdatedAtDefaultsKey)
        if stored > 0 { return stored }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let mtime = attrs[.modificationDate] as? Date {
            return mtime.timeIntervalSince1970
        }
        return 0
    }

    private static func normalizeTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }
}
