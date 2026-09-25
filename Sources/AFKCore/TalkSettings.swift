import Foundation

public enum TalkMode: String, CaseIterable, Sendable {
    /// Hold the shortcut while speaking; release to finish.
    case hold
    /// Tap the shortcut to start and tap again to finish (holding still works as push-to-talk).
    case handsFree
}

/// Persisted recording preferences.
public struct TalkSettings: Equatable, Sendable {
    public var mode: TalkMode = .hold
    /// Hands-free only: finish automatically once speech pauses.
    public var autoStopAfterPause = false
    /// Core Audio device UID; nil means the system default input.
    public var inputDeviceUID: String?

    public init() {}

    static let modeKey = "talkMode"
    static let autoStopKey = "autoStopAfterPause"
    static let inputDeviceKey = "inputDeviceUID"

    public static func load(from defaults: UserDefaults = .standard) -> TalkSettings {
        var settings = TalkSettings()
        settings.mode = defaults.string(forKey: modeKey).flatMap(TalkMode.init(rawValue:)) ?? .hold
        settings.autoStopAfterPause = defaults.bool(forKey: autoStopKey)
        settings.inputDeviceUID = defaults.string(forKey: inputDeviceKey)
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(autoStopAfterPause, forKey: Self.autoStopKey)
        if let inputDeviceUID {
            defaults.set(inputDeviceUID, forKey: Self.inputDeviceKey)
        } else {
            defaults.removeObject(forKey: Self.inputDeviceKey)
        }
    }
}

/// Decides when a hands-free recording should end on its own, based on when the live
/// transcript last changed (the server only emits new text while it hears speech).
public struct PauseDetector: Sendable {
    public var pause: TimeInterval
    public var noSpeechTimeout: TimeInterval
    public var maxDuration: TimeInterval

    private let startedAt: Date
    private var lastText = ""
    private var lastChangeAt: Date?

    public init(startedAt: Date, pause: TimeInterval = 2.5, noSpeechTimeout: TimeInterval = 10, maxDuration: TimeInterval = 300) {
        self.startedAt = startedAt
        self.pause = pause
        self.noSpeechTimeout = noSpeechTimeout
        self.maxDuration = maxDuration
    }

    public mutating func transcriptChanged(to text: String, at now: Date) {
        guard text != lastText else { return }
        lastText = text
        lastChangeAt = now
    }

    /// `autoStop` gates the pause rule; the no-speech and max-duration limits always apply.
    public func shouldStop(at now: Date, autoStop: Bool) -> Bool {
        if now.timeIntervalSince(startedAt) >= maxDuration { return true }
        guard let lastChangeAt, !lastText.isEmpty else {
            return autoStop && now.timeIntervalSince(startedAt) >= noSpeechTimeout
        }
        return autoStop && now.timeIntervalSince(lastChangeAt) >= pause
    }
}
