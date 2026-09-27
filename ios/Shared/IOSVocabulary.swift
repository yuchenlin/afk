import Foundation

/// Lightweight lexicon for iOS (mirrors Mac `LexiconStore` / `VocabularyStore`).
/// Stored in the App Group so host STT + polish share the same terms; seeded from the
/// Mac `Resources/lexicon.example.txt` defaults; editable in Settings → Vocabulary.
///
/// Cross-device sync (Mac ↔ iOS) uses iCloud Key-Value Store:
/// - Keys: `afk.vocabularyText` + `afk.vocabularyUpdatedAt` (same as Mac)
/// - Shared KVS id: `$(TeamIdentifierPrefix)xyz.yuchenlin.afk`
/// - Merge: **last-writer-wins on the whole text**
/// - App Group remains the same-device source for keyboard/host; KVS is cross-device.
/// - Not signed into iCloud → local App Group only (no errors).
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

public enum IOSVocabulary {
    public static let defaultsKey = "settings.vocabularyText"
    public static let localUpdatedAtKey = "settings.vocabularyUpdatedAt"

    /// Must match Mac `VocabularyStore.iCloudTextKey` / `iCloudUpdatedAtKey`.
    public static let iCloudTextKey = "afk.vocabularyText"
    public static let iCloudUpdatedAtKey = "afk.vocabularyUpdatedAt"

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

    public static var isiCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    public static func loadText(from defaults: UserDefaults = SessionRelay.shared.defaults) -> String {
        if let saved = defaults.string(forKey: defaultsKey), !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return saved
        }
        return bundledDefaults
    }

    public static func load(from defaults: UserDefaults = SessionRelay.shared.defaults) -> IOSLexicon {
        IOSLexicon(from: loadText(from: defaults))
    }

    /// Writes App Group local store and pushes to iCloud KVS when available.
    public static func save(_ text: String, to defaults: UserDefaults = SessionRelay.shared.defaults) {
        var contents = text
        if !contents.hasSuffix("\n") { contents += "\n" }
        let now = Date().timeIntervalSince1970
        writeLocal(contents, to: defaults, updatedAt: now)
        pushToiCloud(contents, updatedAt: now)
    }

    /// Pull remote if newer (or seed empty KVS from App Group). Returns whether local changed.
    @discardableResult
    public static func pullFromiCloudIfNewer(to defaults: UserDefaults = SessionRelay.shared.defaults) -> Bool {
        guard isiCloudAvailable else { return false }
        let store = NSUbiquitousKeyValueStore.default
        _ = store.synchronize()

        guard let remote = store.string(forKey: iCloudTextKey) else {
            seediCloudFromLocalIfNeeded(defaults: defaults)
            return false
        }

        let remoteTs = store.object(forKey: iCloudUpdatedAtKey) as? Double ?? 0
        let localTs = defaults.double(forKey: localUpdatedAtKey)
        let remoteNormalized = normalizeTrailingNewline(remote)
        let localNormalized = normalizeTrailingNewline(defaults.string(forKey: defaultsKey) ?? "")

        if remoteTs > localTs || (localTs == 0 && defaults.string(forKey: defaultsKey) == nil) {
            if remoteNormalized != localNormalized {
                let ts = remoteTs > 0 ? remoteTs : Date().timeIntervalSince1970
                writeLocal(remoteNormalized, to: defaults, updatedAt: ts)
                return true
            }
            return false
        }

        if localTs > remoteTs,
           let local = defaults.string(forKey: defaultsKey),
           !local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pushToiCloud(normalizeTrailingNewline(local), updatedAt: localTs)
        }
        return false
    }

    /// Observe remote KVS edits; callback on the main queue.
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

    private static func writeLocal(_ contents: String, to defaults: UserDefaults, updatedAt: TimeInterval) {
        defaults.set(contents, forKey: defaultsKey)
        defaults.set(updatedAt, forKey: localUpdatedAtKey)
        defaults.synchronize()
    }

    private static func pushToiCloud(_ text: String, updatedAt: TimeInterval) {
        guard isiCloudAvailable else { return }
        let store = NSUbiquitousKeyValueStore.default
        store.set(text, forKey: iCloudTextKey)
        store.set(updatedAt, forKey: iCloudUpdatedAtKey)
        _ = store.synchronize()
    }

    private static func seediCloudFromLocalIfNeeded(defaults: UserDefaults) {
        guard let local = defaults.string(forKey: defaultsKey),
              !local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let ts = defaults.double(forKey: localUpdatedAtKey)
        pushToiCloud(normalizeTrailingNewline(local), updatedAt: ts > 0 ? ts : Date().timeIntervalSince1970)
    }

    private static func normalizeTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }
}
