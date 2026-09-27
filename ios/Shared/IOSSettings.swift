import Foundation

/// Host + keyboard settings persisted in the App Group suite (and API key in Keychain).
public struct IOSSettings: Sendable {
    public var speechModel: String
    public var polishModel: String
    /// Idle minutes before the session mic turns off (reset by each dictation).
    public var sessionMinutes: Int
    public var useMockSTT: Bool
    public var polishEnabled: Bool
    /// Start the session mic whenever AFK comes to the foreground.
    public var autoStartSession: Bool

    public static let `default` = IOSSettings(
        speechModel: AppGroupConstants.defaultSpeechModel,
        polishModel: AppGroupConstants.defaultPolishModel,
        sessionMinutes: AppGroupConstants.defaultSessionMinutes,
        useMockSTT: false,
        polishEnabled: true,
        autoStartSession: true
    )

    public static func load(from defaults: UserDefaults = SessionRelay.shared.defaults) -> IOSSettings {
        var s = IOSSettings.default
        if let m = defaults.string(forKey: AppGroupConstants.settingsSpeechModelKey), !m.isEmpty {
            s.speechModel = m
        }
        if let m = defaults.string(forKey: AppGroupConstants.settingsPolishModelKey), !m.isEmpty {
            s.polishModel = m
        }
        let minutes = defaults.integer(forKey: AppGroupConstants.settingsSessionMinutesKey)
        if minutes > 0 { s.sessionMinutes = minutes }
        if defaults.object(forKey: AppGroupConstants.settingsUseMockSTTKey) != nil {
            s.useMockSTT = defaults.bool(forKey: AppGroupConstants.settingsUseMockSTTKey)
        }
        if defaults.object(forKey: AppGroupConstants.settingsPolishEnabledKey) != nil {
            s.polishEnabled = defaults.bool(forKey: AppGroupConstants.settingsPolishEnabledKey)
        }
        if defaults.object(forKey: AppGroupConstants.settingsAutoStartSessionKey) != nil {
            s.autoStartSession = defaults.bool(forKey: AppGroupConstants.settingsAutoStartSessionKey)
        }
        // A saved xAI key always wins: never leave mock sticky ON (App Group may still
        // have true from older builds that defaulted mock on).
        if KeychainStore.readAPIKey() != nil, s.useMockSTT {
            s.useMockSTT = false
            s.save(to: defaults)
        }
        return s
    }

    public func save(to defaults: UserDefaults = SessionRelay.shared.defaults) {
        defaults.set(speechModel, forKey: AppGroupConstants.settingsSpeechModelKey)
        defaults.set(polishModel, forKey: AppGroupConstants.settingsPolishModelKey)
        defaults.set(sessionMinutes, forKey: AppGroupConstants.settingsSessionMinutesKey)
        defaults.set(useMockSTT, forKey: AppGroupConstants.settingsUseMockSTTKey)
        defaults.set(polishEnabled, forKey: AppGroupConstants.settingsPolishEnabledKey)
        defaults.set(autoStartSession, forKey: AppGroupConstants.settingsAutoStartSessionKey)
        defaults.synchronize()
    }
}
