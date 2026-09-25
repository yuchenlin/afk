import AppKit
import SwiftUI

/// API key (with a live test of both endpoints) and model overrides.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Called after a successful save.
    public var onSave: (() -> Void)?

    private let model = SettingsModel()
    private var window: NSWindow?

    public override init() {
        super.init()
        model.save = { [weak self] in self?.save() }
        model.cancel = { [weak self] in self?.window?.close() }
    }

    public func show() {
        if window == nil { window = makeWindow() }
        model.reload()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func save() {
        do {
            if model.keyEdited {
                try ApiKeyStore.save(model.keyField)
            }
            ModelSettings.save(speech: model.speechModel, polish: model.polishModel)
            onSave?()
            window?.close()
        } catch {
            model.error = "Couldn't save the key: \(error.localizedDescription)"
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AFK Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.delegate = self
        return window
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var keyField = "" {
        didSet { if keyField != loadedKey { keyEdited = true; testResult = nil } }
    }
    @Published var revealKey = false
    @Published var speechModel = ""
    @Published var polishModel = ""
    @Published var testResult: ApiKeyTester.Result?
    @Published var testing = false
    @Published var error: String?
    @Published private(set) var keyEdited = false
    @Published private(set) var environmentOverride = false

    var save: () -> Void = {}
    var cancel: () -> Void = {}
    private var loadedKey = ""

    /// Where the active key comes from, for the status line.
    var activeKeyDescription: String {
        if environmentOverride, let active = ApiKeyStore.load() {
            return "Active key: \(ApiKeyStore.masked(active.key)) from the XAI_API_KEY_VOICE environment variable, which overrides the saved key."
        }
        let saved = ApiKeyStore.readKeyFile()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if saved.isEmpty { return "No key saved yet. Paste your xAI API key and click Save." }
        return "Active key: \(ApiKeyStore.masked(saved)), saved for AFK only (not in the app or repo)."
    }

    func reload() {
        let saved = ApiKeyStore.readKeyFile()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        loadedKey = saved
        keyField = saved
        keyEdited = false
        revealKey = false
        environmentOverride = ApiKeyStore.load()?.source == .environment
        speechModel = ModelSettings.speechModel()
        polishModel = ModelSettings.polishModel()
        testResult = nil
        error = nil
    }

    func resetModels() {
        speechModel = ModelSettings.defaultSpeechModel
        polishModel = ModelSettings.defaultPolishModel
        testResult = nil
    }

    /// Tests the key in the field (or the active key if the field is empty) with the models shown.
    func test() {
        let typed = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = typed.isEmpty ? ApiKeyStore.load()?.key : typed else {
            error = "Paste a key first."
            return
        }
        error = nil
        testing = true
        testResult = nil
        ApiKeyTester.test(
            key: key,
            speechModel: speechModel.isEmpty ? ModelSettings.defaultSpeechModel : speechModel,
            polishModel: polishModel.isEmpty ? ModelSettings.defaultPolishModel : polishModel
        ) { [weak self] result in
            self?.testing = false
            self?.testResult = result
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Text("xAI API Key").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Group {
                            if model.revealKey {
                                TextField("xai-…", text: $model.keyField)
                            } else {
                                SecureField("xai-…", text: $model.keyField)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        Button(model.revealKey ? "Hide" : "Show") { model.revealKey.toggle() }
                    }
                    Text(model.activeKeyDescription)
                        .font(.caption)
                        .foregroundColor(model.environmentOverride ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button("Test Key", action: model.test)
                            .disabled(model.testing)
                        if model.testing {
                            ProgressView().controlSize(.small)
                            Text("Testing speech-to-text and polish…").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if let result = model.testResult {
                        CheckRow(label: "Speech-to-text", check: result.speech)
                        CheckRow(label: "Polish (chat)", check: result.polish)
                        if result.speech.isOK && !result.polish.isOK {
                            Text("Dictation will work; Polished output will fall back to the original text.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(6)
            }

            GroupBox(label: Text("Models (Advanced)").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledField(label: "Speech-to-text", text: $model.speechModel, placeholder: ModelSettings.defaultSpeechModel)
                    LabeledField(label: "Polish", text: $model.polishModel, placeholder: ModelSettings.defaultPolishModel)
                    HStack {
                        Text("Test Key checks these models too.")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Reset to Defaults", action: model.resetModels)
                    }
                }
                .padding(6)
            }

            if let error = model.error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", action: model.cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: model.save)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 540, height: 470)
    }
}

private struct CheckRow: View {
    let label: String
    let check: KeyCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: check.isOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundColor(check.isOK ? .green : .red)
            Text("\(label):").fontWeight(.medium)
            Text(check.summary)
                .foregroundColor(check.isOK ? .primary : .red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
