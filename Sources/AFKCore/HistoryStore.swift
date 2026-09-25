import Foundation
import os

private let historyLog = Logger(subsystem: "xyz.yuchenlin.afk", category: "history")

public struct TranscriptEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let text: String
    /// Seconds of audio recorded.
    public let duration: TimeInterval?
    /// App that was frontmost when the transcript arrived (where it was pasted).
    public let appName: String?
    public let pasted: Bool

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        duration: TimeInterval? = nil,
        appName: String? = nil,
        pasted: Bool
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.duration = duration
        self.appName = appName
        self.pasted = pasted
    }
}

/// Every transcript, newest first, persisted as JSON (mode 600) on each change.
@MainActor
public final class HistoryStore: ObservableObject {
    @Published public private(set) var entries: [TranscriptEntry] = []
    public let fileURL: URL

    public nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AFK/history.json")
    }

    public init(fileURL: URL = HistoryStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    public func add(_ entry: TranscriptEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    public func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    public func clear() {
        entries.removeAll()
        save()
    }

    /// Case- and accent-insensitive match on the text or app name; empty query returns all.
    public func search(_ query: String) -> [TranscriptEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entries.filter {
            $0.text.range(of: q, options: options) != nil
                || ($0.appName?.range(of: q, options: options) != nil)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            entries = try Self.decoder.decode([TranscriptEntry].self, from: data)
                .sorted { $0.date > $1.date }
        } catch {
            // Keep the unreadable file instead of overwriting it on the next save.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent()
                .appendingPathComponent("history-unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            historyLog.error("history unreadable, moved to \(aside.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            historyLog.error("couldn't save history: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// ISO 8601 with milliseconds, so entries round-trip exactly and keep their order.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(f.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: raw) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(raw)"))
        }
        return d
    }()
}
