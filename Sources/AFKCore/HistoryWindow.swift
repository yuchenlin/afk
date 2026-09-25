import AppKit
import SwiftUI

/// Browse, search, copy, re-paste, and delete past transcripts.
@MainActor
public final class HistoryWindowController: NSObject, NSWindowDelegate {
    private let store: HistoryStore
    private let paste: (String) -> Void
    private var window: NSWindow?

    /// `paste` inserts text into the app that was active before the history window.
    public init(store: HistoryStore, paste: @escaping (String) -> Void) {
        self.store = store
        self.paste = paste
        super.init()
    }

    public func show() {
        if window == nil { window = makeWindow() }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func pasteIntoPreviousApp(_ text: String) {
        window?.close()
        // Hiding AFK hands focus back to the previously active app before pasting.
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [paste] in paste(text) }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AFK History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 320)
        window.contentView = NSHostingView(rootView: HistoryView(
            store: store,
            paste: { [weak self] in self?.pasteIntoPreviousApp($0) }
        ))
        window.delegate = self
        return window
    }
}

private struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    let paste: (String) -> Void

    @State private var query = ""
    @State private var selection = Set<UUID>()
    @State private var confirmClear = false
    @State private var copiedAt: Date?

    private var filtered: [TranscriptEntry] { store.search(query) }

    /// Selected entries in chronological order (oldest first), for copying several at once.
    private var selectedEntries: [TranscriptEntry] {
        store.entries.filter { selection.contains($0.id) }.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search transcripts or apps", text: $query)
                    .textFieldStyle(.roundedBorder)
                Text(query.isEmpty ? "\(store.entries.count) transcripts" : "\(filtered.count) of \(store.entries.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .padding(12)

            Divider()

            if store.entries.isEmpty {
                placeholder("No transcripts yet. Dictate with your AFK shortcut and they'll appear here.")
            } else if filtered.isEmpty {
                placeholder("No transcripts match “\(query)”.")
            } else {
                List(filtered, selection: $selection) { entry in
                    HistoryRow(entry: entry)
                        .tag(entry.id)
                        .contextMenu {
                            Button("Copy") { copy([entry]) }
                            if let raw = entry.rawText {
                                Button("Copy Original (Before Polish)") { copyText(raw) }
                            }
                            Button("Paste into Previous App") { paste(entry.text) }
                            Divider()
                            Button("Delete") { delete([entry.id]) }
                        }
                }
                .onCopyCommand {
                    copy(selectedEntries)
                    return []
                }
                .onDeleteCommand { delete(selection) }
            }

            Divider()

            HStack {
                Button("Copy") { copy(selectedEntries) }
                    .disabled(selection.isEmpty)
                Button("Paste into Previous App") {
                    if let entry = selectedEntries.first { paste(entry.text) }
                }
                .disabled(selection.count != 1)
                Button("Delete") { delete(selection) }
                    .disabled(selection.isEmpty)
                if let copiedAt, Date().timeIntervalSince(copiedAt) < 2 {
                    Text("Copied").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Clear All…") { confirmClear = true }
                    .disabled(store.entries.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 320)
        .alert("Delete all \(store.entries.count) transcripts?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) {
                store.clear()
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ entries: [TranscriptEntry]) {
        guard !entries.isEmpty else { return }
        copyText(entries.map(\.text).joined(separator: "\n\n"))
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { copiedAt = copiedAt }
    }

    private func delete(_ ids: Set<UUID>) {
        store.delete(ids: ids)
        selection.subtract(ids)
    }
}

private struct HistoryRow: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.text)
                .lineLimit(3)
                .textSelection(.enabled)
            if let raw = entry.rawText {
                Text("Original: \(raw)")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Text(details)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var details: String {
        var parts = [Self.dateFormatter.string(from: entry.date)]
        if let app = entry.appName { parts.append(entry.pasted ? "pasted into \(app)" : app) }
        if !entry.pasted { parts.append("not pasted") }
        if entry.rawText != nil { parts.append("polished") }
        if let duration = entry.duration { parts.append(String(format: "%.1f s", duration)) }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}
