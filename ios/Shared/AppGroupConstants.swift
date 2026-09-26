import Foundation

/// Shared identifiers for the host app ↔ keyboard extension relay.
///
/// **Setup:** In Xcode, set your Team on both targets and ensure the App Group
/// capability uses this exact id (or update every reference if you change it).
public enum AppGroupConstants {
    /// Placeholder App Group — must match entitlements on both targets.
    public static let suiteName = "group.xyz.yuchenlin.afk"

    public static let hostBundleID = "xyz.yuchenlin.afk.ios"
    public static let keyboardBundleID = "xyz.yuchenlin.afk.ios.keyboard"

    // UserDefaults (App Group) keys
    public static let sessionActiveKey = "session.active"
    public static let sessionExpiresAtKey = "session.expiresAt"
    public static let recordingActiveKey = "recording.active"
    public static let lastResultTextKey = "result.text"
    public static let lastResultIDKey = "result.id"
    public static let lastErrorKey = "result.error"
    public static let statusMessageKey = "status.message"
    public static let settingsSpeechModelKey = "settings.speechModel"
    public static let settingsPolishModelKey = "settings.polishModel"
    public static let settingsSessionMinutesKey = "settings.sessionMinutes"
    public static let settingsUseMockSTTKey = "settings.useMockSTT"
    public static let settingsPolishEnabledKey = "settings.polishEnabled"

    // Darwin notification names (CFNotificationCenter distributed)
    public static let noteStartRecording = "xyz.yuchenlin.afk.ios.startRecording"
    public static let noteStopRecording = "xyz.yuchenlin.afk.ios.stopRecording"
    public static let noteResultReady = "xyz.yuchenlin.afk.ios.resultReady"
    public static let noteSessionChanged = "xyz.yuchenlin.afk.ios.sessionChanged"
    public static let noteOpenHost = "xyz.yuchenlin.afk.ios.openHost"

    public static let defaultSpeechModel = "grok-voice-transcribe-2.0"
    public static let defaultPolishModel = "grok-4-1-fast-non-reasoning"
    public static let defaultSessionMinutes = 15
}
