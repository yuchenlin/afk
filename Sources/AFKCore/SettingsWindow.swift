import AppKit
import SwiftUI

/// Providers, models and API keys for speech-to-text and polish, with a live test.
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
            try model.persist()
            onSave?()
            window?.close()
        } catch {
            model.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
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
    struct StageState: Equatable {
        var provider: Provider = .xai
        var model = ""
    }

    @Published var speech = StageState() { didSet { if speech.provider != oldValue.provider { providerChanged(.speech) } } }
    @Published var polish = StageState() { didSet { if polish.provider != oldValue.provider { providerChanged(.polish) } } }
    @Published var baseURLs: [Provider: String] = [:]
    @Published var keys: [Provider: String] = [:]
    @Published var revealKeys = false
    @Published var testResult: ApiKeyTester.Result?
    @Published var testing = false
    @Published var error: String?
    @Published var browsing: [Provider: [String]] = [:]

    var save: () -> Void = {}
    var cancel: () -> Void = {}
    private var loadedKeys: [Provider: String] = [:]

    static let keyedProviders: [Provider] = [.xai, .openrouter, .openai, .custom]

    func reload() {
        for provider in Provider.allCases {
            baseURLs[provider] = ProviderSettings.baseURL(for: provider)
        }
        for provider in Self.keyedProviders {
            let saved = ApiKeyStore.readKeyFile(for: provider) ?? ""
            loadedKeys[provider] = saved
            keys[provider] = saved
        }
        let sp = ProviderSettings.provider(for: .speech)
        let pp = ProviderSettings.provider(for: .polish)
        speech = StageState(provider: sp, model: ProviderSettings.model(for: .speech, provider: sp))
        polish = StageState(provider: pp, model: ProviderSettings.model(for: .polish, provider: pp))
        revealKeys = false
        testResult = nil
        error = nil
    }

    private func providerChanged(_ stage: Stage) {
        testResult = nil
        switch stage {
        case .speech: speech.model = ProviderSettings.model(for: .speech, provider: speech.provider)
        case .polish: polish.model = ProviderSettings.model(for: .polish, provider: polish.provider)
        }
    }

    func persist() throws {
        for provider in Self.keyedProviders where (keys[provider] ?? "") != (loadedKeys[provider] ?? "") {
            try ApiKeyStore.save(keys[provider] ?? "", for: provider)
        }
        for provider in Provider.allCases where provider.hasEditableBaseURL {
            ProviderSettings.setBaseURL(baseURLs[provider] ?? "", for: provider)
        }
        ProviderSettings.setProvider(speech.provider, for: .speech)
        ProviderSettings.setModel(speech.model, for: .speech, provider: speech.provider)
        ProviderSettings.setProvider(polish.provider, for: .polish)
        ProviderSettings.setModel(polish.model, for: .polish, provider: polish.provider)
    }

    /// The endpoint the form currently describes (unsaved edits included).
    func endpoint(for stage: Stage) -> Endpoint {
        let state = stage == .speech ? speech : polish
        let typedKey = (keys[state.provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typedKey.isEmpty ? ApiKeyStore.load(for: state.provider)?.key : typedKey
        let model = state.model.isEmpty ? state.provider.defaultModel(for: stage) : state.model
        let base = state.provider.hasEditableBaseURL ? (baseURLs[state.provider] ?? "") : state.provider.defaultBaseURL
        return Endpoint(provider: state.provider, baseURL: base, apiKey: key, model: model)
    }

    func keyStatus(_ provider: Provider) -> String {
        if let env = provider.environmentName, let active = ApiKeyStore.load(for: provider), active.source == .environment {
            return "Using \(ApiKeyStore.masked(active.key)) from \(env), which overrides a saved key."
        }
        let saved = (keys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if saved.isEmpty { return provider.requiresKey ? "No key saved." : "Optional — only if your server requires one." }
        return "Saved: \(ApiKeyStore.masked(saved))"
    }

    var keysInUse: Set<Provider> { [speech.provider, polish.provider] }

    func test() {
        error = nil
        testing = true
        testResult = nil
        ApiKeyTester.test(speech: endpoint(for: .speech), polish: endpoint(for: .polish)) { [weak self] result in
            self?.testing = false
            self?.testResult = result
        }
    }

    /// Lists models from a local server's `/models` (Ollama and most OpenAI-compatible servers).
    func browseModels(_ provider: Provider) {
        guard let url = URL(string: (baseURLs[provider] ?? "") + "/models") else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        let key = (keys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        URLSession.shared.dataTask(with: request) { data, _, error in
            let ids = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["data"] as? [[String: Any]])?
                .compactMap { $0["id"] as? String }.sorted() ?? []
            let message = error.map { _ in "Can't reach \(url.deletingLastPathComponent().absoluteString) — is the server running?" }
            Task { @MainActor [weak self] in
                self?.browsing[provider] = ids
                if ids.isEmpty { self?.error = message ?? "No models found on \(provider.displayName)." }
            }
        }.resume()
    }

    func resetModel(_ stage: Stage) {
        switch stage {
        case .speech: speech.model = speech.provider.defaultModel(for: .speech)
        case .polish: polish.model = polish.provider.defaultModel(for: .polish)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private var speechNote: String {
        switch model.speech.provider {
        case .xai: return "Streams while you talk (live text in the pill)."
        case .whisper: return "Runs on this Mac. Start the server with scripts/local-whisper.sh (downloads a model from Hugging Face)."
        default: return "Sends the recording when you stop — no live text; usually 0.5–2 s."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StageBox(title: "Speech-to-text", stage: .speech, model: model,
                     note: speechNote)
            StageBox(title: "Polish", stage: .polish, model: model,
                     note: model.polish.provider == .ollama ? "Runs on this Mac. The first request loads the model and can take a few seconds." : nil)

            GroupBox(label: Text("API Keys").font(.headline)) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(SettingsModel.keyedProviders, id: \.self) { provider in
                        KeyRow(provider: provider, model: model)
                    }
                    Toggle("Show keys", isOn: $model.revealKeys).font(.caption)
                }
                .padding(6)
            }

            HStack(spacing: 10) {
                Button("Test", action: model.test).disabled(model.testing)
                if model.testing {
                    ProgressView().controlSize(.small)
                    Text("Testing speech-to-text and polish…").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            if let result = model.testResult {
                CheckRow(label: "Speech (\(model.speech.provider.displayName))", check: result.speech)
                CheckRow(label: "Polish (\(model.polish.provider.displayName))", check: result.polish)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            Spacer(minLength: 0)
            HStack {
                Text("Keys are saved only on this Mac, readable by your user.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: model.save)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 600, height: 700)
    }
}

private struct StageBox: View {
    let title: String
    let stage: Stage
    @ObservedObject var model: SettingsModel
    let note: String?

    private var state: Binding<SettingsModel.StageState> {
        stage == .speech ? $model.speech : $model.polish
    }

    var body: some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Provider").frame(width: 80, alignment: .leading)
                    Picker("", selection: state.provider) {
                        ForEach(Provider.available(for: stage), id: \.self) { provider in
                            Text(provider == .xai ? "\(provider.displayName) (default)" : provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                }
                if state.wrappedValue.provider.hasEditableBaseURL {
                    HStack {
                        Text("Server").frame(width: 80, alignment: .leading)
                        TextField("http://localhost:1234/v1", text: Binding(
                            get: { model.baseURLs[state.wrappedValue.provider] ?? "" },
                            set: { model.baseURLs[state.wrappedValue.provider] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
                HStack {
                    Text("Model").frame(width: 80, alignment: .leading)
                    TextField(state.wrappedValue.provider.defaultModel(for: stage), text: state.model)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    if state.wrappedValue.provider.listsModels {
                        let provider = state.wrappedValue.provider
                        Menu("Browse") {
                            ForEach(model.browsing[provider] ?? [], id: \.self) { id in
                                Button(id) { state.model.wrappedValue = id }
                            }
                            if (model.browsing[provider] ?? []).isEmpty {
                                Button("Load models from server") { model.browseModels(provider) }
                            } else {
                                Divider()
                                Button("Reload") { model.browseModels(provider) }
                            }
                        }
                        .frame(width: 90)
                    }
                    Button("Default") { model.resetModel(stage) }
                }
                if let note {
                    Text(note).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(6)
        }
    }
}

private struct KeyRow: View {
    let provider: Provider
    @ObservedObject var model: SettingsModel

    var body: some View {
        let binding = Binding(get: { model.keys[provider] ?? "" }, set: { model.keys[provider] = $0 })
        HStack(alignment: .firstTextBaseline) {
            Text(provider == .custom ? "Custom" : provider.displayName)
                .fontWeight(model.keysInUse.contains(provider) ? .semibold : .regular)
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if model.revealKeys {
                        TextField(provider.requiresKey ? "Paste API key" : "Optional", text: binding)
                    } else {
                        SecureField(provider.requiresKey ? "Paste API key" : "Optional", text: binding)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                Text(model.keyStatus(provider)).font(.caption2).foregroundColor(.secondary)
            }
        }
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
