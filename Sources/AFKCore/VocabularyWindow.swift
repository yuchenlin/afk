import AppKit
import SwiftUI

/// Editor for the custom vocabulary (one term per line), sent to Grok as key terms.
@MainActor
public final class VocabularyWindowController: NSObject, NSWindowDelegate {
    /// Called with the saved vocabulary.
    public var onSave: ((LexiconStore) -> Void)?

    private let model = VocabularyEditorModel()
    private var window: NSWindow?

    public override init() {
        super.init()
        model.save = { [weak self] in self?.save() }
        model.cancel = { [weak self] in self?.window?.close() }
    }

    public func show() {
        if window == nil { window = makeWindow() }
        model.text = VocabularyStore.loadText()
        model.error = nil
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func save() {
        do {
            try VocabularyStore.save(model.text)
            onSave?(LexiconStore(from: model.text))
            window?.close()
        } catch {
            model.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AFK Vocabulary"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 380)
        window.contentView = NSHostingView(rootView: VocabularyEditorView(model: model))
        window.delegate = self
        return window
    }
}

@MainActor
final class VocabularyEditorModel: ObservableObject {
    @Published var text = ""
    @Published var error: String?
    var save: () -> Void = {}
    var cancel: () -> Void = {}

    var lexicon: LexiconStore { LexiconStore(from: text) }
}

private struct VocabularyEditorView: View {
    @ObservedObject var model: VocabularyEditorModel

    var body: some View {
        let lexicon = model.lexicon
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom Vocabulary")
                .font(.headline)
            Text("One word or phrase per line: names, product terms, jargon (e.g. GRPO, Hotshot, 宇辰). AFK sends them to Grok as key terms so they're recognized and spelled exactly as written. Lines starting with # are comments. Syncs with iPhone via iCloud (same Apple ID); last save wins for the whole list.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $model.text)
                .font(.system(size: 13, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(lexicon.keyTermsForStt.count) / \(LexiconStore.maxKeyTerms) terms")
                    .monospacedDigit()
                if !lexicon.tooLongTerms.isEmpty {
                    Text("Over \(LexiconStore.maxTermLength) characters, not sent: \(lexicon.tooLongTerms.joined(separator: ", "))")
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
                if lexicon.overLimitCount > 0 {
                    Text("\(lexicon.overLimitCount) term(s) past the first \(LexiconStore.maxKeyTerms) are not sent")
                        .foregroundColor(.orange)
                }
                if let error = model.error {
                    Text(error).foregroundColor(.red)
                }
            }
            .font(.caption)

            HStack {
                Button("Reset to Examples") {
                    model.text = VocabularyStore.bundledText ?? ""
                }
                .disabled(VocabularyStore.bundledText == nil)
                Spacer()
                Button("Cancel", action: model.cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: model.save)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 380)
    }
}
