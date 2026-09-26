import Foundation

/// The two API calls AFK makes; each can use a different provider.
public enum Stage: String, CaseIterable, Sendable {
    case speech
    case polish
}

/// API providers. Everything except xAI speech uses the OpenAI-compatible format
/// (`/audio/transcriptions`, `/chat/completions`), so one client covers them all.
public enum Provider: String, CaseIterable, Sendable {
    case xai
    case openrouter
    case openai
    case ollama
    case whisper
    case custom

    public var displayName: String {
        switch self {
        case .xai: return "xAI Grok"
        case .openrouter: return "OpenRouter"
        case .openai: return "OpenAI"
        case .ollama: return "Ollama (local)"
        case .whisper: return "Local Whisper (whisper.cpp)"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .xai: return "https://api.x.ai/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .openai: return "https://api.openai.com/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .whisper: return "http://127.0.0.1:8178/v1"
        case .custom: return ""
        }
    }

    /// Servers the user runs locally take an editable base URL.
    public var hasEditableBaseURL: Bool { self == .ollama || self == .whisper || self == .custom }

    /// Ollama only does chat; whisper.cpp only does speech-to-text.
    public func supports(_ stage: Stage) -> Bool {
        switch self {
        case .ollama: return stage == .polish
        case .whisper: return stage == .speech
        default: return true
        }
    }

    /// Whether the server lists its models at `/models` (whisper.cpp serves one fixed model).
    public var listsModels: Bool { self == .ollama || self == .custom }

    /// Local servers usually don't need a key.
    public var requiresKey: Bool { self == .xai || self == .openrouter || self == .openai }
    public var usesKey: Bool { self != .ollama && self != .whisper }

    /// Environment variable checked before the key file (when AFK is launched from a shell).
    public var environmentName: String? {
        switch self {
        case .xai: return "XAI_API_KEY_VOICE"
        case .openrouter: return "OPENROUTER_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        case .ollama, .whisper, .custom: return nil
        }
    }

    public var keyFileName: String { "\(rawValue)-api-key" }

    public func defaultModel(for stage: Stage) -> String {
        switch (self, stage) {
        case (.xai, .speech): return "grok-voice-transcribe-2.0"
        case (.xai, .polish): return "grok-4-1-fast-non-reasoning"
        case (.openrouter, .speech): return "qwen/qwen3-asr-1.7b"
        case (.openrouter, .polish): return "google/gemini-2.5-flash-lite"
        case (.openai, .speech): return "gpt-4o-mini-transcribe"
        case (.openai, .polish): return "gpt-4.1-mini"
        case (.ollama, _): return "qwen2.5:0.5b"
        // whisper.cpp ignores the name and uses the model it was started with.
        case (.whisper, _): return "whisper"
        case (.custom, .speech): return "whisper-1"
        case (.custom, .polish): return ""
        }
    }

    public static func available(for stage: Stage) -> [Provider] {
        allCases.filter { $0.supports(stage) }
    }
}

/// Provider choices and per-provider model / base URL overrides, stored in UserDefaults.
/// Empty or default values clear the override so future default changes apply.
public enum ProviderSettings {
    public static func provider(for stage: Stage, _ d: UserDefaults = .standard) -> Provider {
        let p = d.string(forKey: "provider.\(stage.rawValue)").flatMap(Provider.init(rawValue:)) ?? .xai
        return p.supports(stage) ? p : .xai
    }

    public static func setProvider(_ provider: Provider, for stage: Stage, _ d: UserDefaults = .standard) {
        if provider == .xai { d.removeObject(forKey: "provider.\(stage.rawValue)") } else { d.set(provider.rawValue, forKey: "provider.\(stage.rawValue)") }
    }

    public static func model(for stage: Stage, provider: Provider, _ d: UserDefaults = .standard) -> String {
        nonEmpty(d.string(forKey: modelKey(stage, provider))) ?? provider.defaultModel(for: stage)
    }

    public static func setModel(_ model: String, for stage: Stage, provider: Provider, _ d: UserDefaults = .standard) {
        store(model, default: provider.defaultModel(for: stage), key: modelKey(stage, provider), d)
    }

    public static func baseURL(for provider: Provider, _ d: UserDefaults = .standard) -> String {
        guard provider.hasEditableBaseURL else { return provider.defaultBaseURL }
        return nonEmpty(d.string(forKey: "baseURL.\(provider.rawValue)")) ?? provider.defaultBaseURL
    }

    public static func setBaseURL(_ url: String, for provider: Provider, _ d: UserDefaults = .standard) {
        guard provider.hasEditableBaseURL else { return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        store(trimmed, default: provider.defaultBaseURL, key: "baseURL.\(provider.rawValue)", d)
    }

    /// xAI keeps the keys used before providers existed ("sttModel", "polishModel").
    static func modelKey(_ stage: Stage, _ provider: Provider) -> String {
        if provider == .xai { return stage == .speech ? "sttModel" : "polishModel" }
        return "model.\(stage.rawValue).\(provider.rawValue)"
    }

    private static func store(_ value: String, default def: String, key: String, _ d: UserDefaults) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty || v == def { d.removeObject(forKey: key) } else { d.set(v, forKey: key) }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// Everything needed to call one provider for one stage.
public struct Endpoint: Sendable, Equatable {
    public var provider: Provider
    public var baseURL: String
    public var apiKey: String?
    public var model: String

    public init(provider: Provider, baseURL: String? = nil, apiKey: String?, model: String) {
        self.provider = provider
        self.baseURL = (baseURL ?? provider.defaultBaseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        self.model = model
    }

    /// The configured endpoint for `stage`, or nil with a user-facing reason.
    public static func current(for stage: Stage) -> Result<Endpoint, EndpointProblem> {
        let provider = ProviderSettings.provider(for: stage)
        let key = ApiKeyStore.load(for: provider)?.key
        if provider.requiresKey && key == nil { return .failure(.missingKey(provider)) }
        let base = ProviderSettings.baseURL(for: provider)
        if base.isEmpty { return .failure(.missingBaseURL(provider)) }
        let model = ProviderSettings.model(for: stage, provider: provider)
        if model.isEmpty { return .failure(.missingModel(provider)) }
        return .success(Endpoint(provider: provider, baseURL: base, apiKey: key, model: model))
    }

    func url(_ path: String) -> URL? { URL(string: baseURL + path) }

    func authorize(_ request: inout URLRequest) {
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if provider == .openrouter {
            // Attribution headers OpenRouter recommends; harmless elsewhere.
            request.setValue("https://github.com/yuchenlin/afk", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("AFK", forHTTPHeaderField: "X-Title")
        }
    }
}

public enum EndpointProblem: Error, Equatable, LocalizedError {
    case missingKey(Provider)
    case missingBaseURL(Provider)
    case missingModel(Provider)

    public var errorDescription: String? {
        switch self {
        case let .missingKey(p): return "No \(p.displayName) API key — open AFK → Settings…"
        case let .missingBaseURL(p): return "No server URL for \(p.displayName) — open AFK → Settings…"
        case let .missingModel(p): return "No model set for \(p.displayName) — open AFK → Settings…"
        }
    }
}
