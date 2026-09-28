import Foundation

/// Resolves API keys from the environment (shell launches) or a private file under
/// `~/Library/Application Support/AFK/`. Environment wins when both are set.
public enum ApiKeyStore {
    public enum Source: Equatable, Sendable {
        case environment
        case keyFile
    }

    public struct Loaded: Equatable, Sendable {
        public var key: String
        public var source: Source
    }

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AFK", isDirectory: true)
    }

    public static func keyFileURL(for provider: Provider) -> URL {
        supportDirectory.appendingPathComponent(provider.keyFileName, isDirectory: false)
    }

    public static func readKeyFile(for provider: Provider) -> String? {
        readKeyFile(at: keyFileURL(for: provider))
    }

    public static func readKeyFile(at url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func save(_ key: String, for provider: Provider) throws {
        try save(key, to: keyFileURL(for: provider))
    }

    /// Writes a 0600 key file (directory 0700). Empty / whitespace removes the file.
    public static func save(_ key: String, to url: URL) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        if trimmed.isEmpty {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            return
        }
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try trimmed.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(
        for provider: Provider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keyFile: (() -> String?)? = nil
    ) -> Loaded? {
        if let name = provider.environmentName {
            let fromEnv = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !fromEnv.isEmpty {
                return Loaded(key: fromEnv, source: .environment)
            }
        }
        // An injected reader replaces the real file entirely, so tests never read real keys.
        let raw = keyFile.map { $0() } ?? readKeyFile(for: provider)
        let fromFile = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromFile.isEmpty {
            return Loaded(key: fromFile, source: .keyFile)
        }
        return nil
    }

    /// xAI-only helper used by older tests: reads `XAI_API_KEY_VOICE`, never `XAI_API_KEY`.
    public static func load(
        environment: [String: String],
        keyFile: @escaping () -> String?
    ) -> Loaded? {
        load(for: .xai, environment: environment, keyFile: keyFile)
    }

    public static func masked(_ key: String) -> String {
        if key.count <= 8 {
            return String(repeating: "•", count: key.count)
        }
        return "\(key.prefix(4))…\(key.suffix(4))"
    }
}
