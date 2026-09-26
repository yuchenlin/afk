import Foundation

/// Shared identifiers for the host app ↔ keyboard extension relay.
///
/// **Setup:** In Xcode, set your Team on both targets and ensure the App Group
/// capability uses this exact id (or update every reference if you change it).
public enum AppGroupConstants {
    /// Must match entitlements on both targets.
    public static let suiteName = "group.xyz.yuchenlin.afk"

    /// Keychain access group (TeamID prefix applied at runtime / via entitlements).
    public static let keychainAccessGroupSuffix = "xyz.yuchenlin.afk.shared"
    /// Team 6FQUWPKXD8 — must match DEVELOPMENT_TEAM / entitlements AppIdentifierPrefix.
    public static let keychainAccessGroup = "6FQUWPKXD8.xyz.yuchenlin.afk.shared"

    public static let hostBundleID = "xyz.yuchenlin.afk.ios"
    public static let keyboardBundleID = "xyz.yuchenlin.afk.ios.keyboard"

    // UserDefaults (App Group) keys
    public static let sessionActiveKey = "session.active"
    public static let sessionExpiresAtKey = "session.expiresAt"
    public static let recordingActiveKey = "recording.active"
    public static let recordingLevelKey = "recording.level"
    public static let lastResultTextKey = "result.text"
    public static let lastResultIDKey = "result.id"
    public static let lastErrorKey = "result.error"
    public static let statusMessageKey = "status.message"
    public static let settingsSpeechModelKey = "settings.speechModel"
    public static let settingsPolishModelKey = "settings.polishModel"
    public static let settingsSessionMinutesKey = "settings.sessionMinutes"
    public static let settingsUseMockSTTKey = "settings.useMockSTT"
    public static let settingsPolishEnabledKey = "settings.polishEnabled"

    /// Keyboard → host command channel (survives missed Darwin notifies).
    /// Values: "" | "start" | "stop"
    public static let commandActionKey = "command.action"
    public static let commandIDKey = "command.id"
    public static let commandAtKey = "command.at"
    public static let lastConsumedCommandIDKey = "command.lastConsumedID"

    /// Host writes wall-clock while session keepalive is running. Keyboard uses this
    /// to detect a suspended/dead host even when session.active is still true.
    public static let hostHeartbeatAtKey = "host.heartbeatAt"
    public static let hostAliveKey = "host.alive"


    // Full Access handshake (host writes challenge; keyboard with Full Access echoes)
    public static let fullAccessHostChallengeKey = "fullAccess.hostChallenge"
    public static let fullAccessHostChallengeAtKey = "fullAccess.hostChallengeAt"
    public static let fullAccessKeyboardEchoKey = "fullAccess.keyboardEcho"
    public static let fullAccessKeyboardReportedKey = "fullAccess.keyboardReported"
    public static let fullAccessKeyboardReportedAtKey = "fullAccess.keyboardReportedAt"
    public static let fullAccessProbeKey = "fullAccess.rwProbe"

    // Darwin notification names (CFNotificationCenter distributed)
    public static let noteStartRecording = "xyz.yuchenlin.afk.ios.startRecording"
    public static let noteStopRecording = "xyz.yuchenlin.afk.ios.stopRecording"
    public static let noteResultReady = "xyz.yuchenlin.afk.ios.resultReady"
    public static let noteSessionChanged = "xyz.yuchenlin.afk.ios.sessionChanged"
    public static let noteOpenHost = "xyz.yuchenlin.afk.ios.openHost"

    /// URL scheme registered by the host (Info.plist). Keyboard opens this when the
    /// host heartbeat is stale so iOS can wake / foreground AFK briefly.
    public static let urlScheme = "afk"
    public static let urlHostWake = "wake"
    public static let urlHostRecord = "record"
    public static let urlHostSession = "session"

    public static let noteFullAccessChanged = "xyz.yuchenlin.afk.ios.fullAccessChanged"

    public static let defaultSpeechModel = "grok-voice-transcribe-2.0"
    public static let defaultPolishModel = "grok-4-1-fast-non-reasoning"
    public static let defaultSessionMinutes = 15
}
