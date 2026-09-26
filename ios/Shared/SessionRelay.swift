import Foundation

/// Read/write shared session + result state via the App Group suite.
public final class SessionRelay {
    public static let shared = SessionRelay()

    public let defaults: UserDefaults
    /// False when the App Group container is missing (entitlement / provisioning problem).
    public let usesAppGroup: Bool

    public enum Command: String {
        case start
        case stop
    }

    public init(suiteName: String = AppGroupConstants.suiteName) {
        let containerOK = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil
        if containerOK, let d = UserDefaults(suiteName: suiteName) {
            self.defaults = d
            self.usesAppGroup = true
        } else if let d = UserDefaults(suiteName: suiteName), containerOK == false {
            // Keyboard without Full Access: suite object may exist but container is nil.
            // Prefer the suite anyway so in-process state works; sharing with host will fail.
            self.defaults = d
            self.usesAppGroup = false
        } else {
            self.defaults = .standard
            self.usesAppGroup = false
        }
    }

    public var isSessionActive: Bool {
        get { defaults.bool(forKey: AppGroupConstants.sessionActiveKey) }
        set {
            defaults.set(newValue, forKey: AppGroupConstants.sessionActiveKey)
            defaults.synchronize()
            DarwinNotify.post(AppGroupConstants.noteSessionChanged)
        }
    }

    public var sessionExpiresAt: Date? {
        get {
            let t = defaults.double(forKey: AppGroupConstants.sessionExpiresAtKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: AppGroupConstants.sessionExpiresAtKey)
            defaults.synchronize()
        }
    }

    public var isRecording: Bool {
        get { defaults.bool(forKey: AppGroupConstants.recordingActiveKey) }
        set {
            defaults.set(newValue, forKey: AppGroupConstants.recordingActiveKey)
            defaults.synchronize()
            DarwinNotify.post(AppGroupConstants.noteSessionChanged)
        }
    }

    /// 0…1 mic level for keyboard waveform (host writes while recording).
    public var recordingLevel: Float {
        get { defaults.float(forKey: AppGroupConstants.recordingLevelKey) }
        set {
            defaults.set(newValue, forKey: AppGroupConstants.recordingLevelKey)
            // No synchronize / Darwin — written at high frequency from audio tap.
        }
    }

    public var statusMessage: String {
        get { defaults.string(forKey: AppGroupConstants.statusMessageKey) ?? "" }
        set {
            defaults.set(newValue, forKey: AppGroupConstants.statusMessageKey)
            defaults.synchronize()
        }
    }

    /// Keyboard: enqueue a start/stop and ping Darwin. Host polls + observes.
    @discardableResult
    public func postCommand(_ command: Command) -> String {
        let id = UUID().uuidString
        defaults.set(command.rawValue, forKey: AppGroupConstants.commandActionKey)
        defaults.set(id, forKey: AppGroupConstants.commandIDKey)
        defaults.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.commandAtKey)
        defaults.synchronize()
        switch command {
        case .start: DarwinNotify.post(AppGroupConstants.noteStartRecording)
        case .stop: DarwinNotify.post(AppGroupConstants.noteStopRecording)
        }
        return id
    }

    /// Host: take the next unconsumed keyboard command, if any.
    public func consumeCommand() -> (id: String, command: Command)? {
        guard let id = defaults.string(forKey: AppGroupConstants.commandIDKey), !id.isEmpty else {
            return nil
        }
        let last = defaults.string(forKey: AppGroupConstants.lastConsumedCommandIDKey)
        guard id != last else { return nil }
        guard let raw = defaults.string(forKey: AppGroupConstants.commandActionKey),
              let command = Command(rawValue: raw) else {
            return nil
        }
        defaults.set(id, forKey: AppGroupConstants.lastConsumedCommandIDKey)
        defaults.removeObject(forKey: AppGroupConstants.commandActionKey)
        defaults.synchronize()
        return (id, command)
    }

    public func publishResult(_ text: String) {
        let id = UUID().uuidString
        defaults.set(text, forKey: AppGroupConstants.lastResultTextKey)
        defaults.set(id, forKey: AppGroupConstants.lastResultIDKey)
        defaults.removeObject(forKey: AppGroupConstants.lastErrorKey)
        defaults.set(0 as Float, forKey: AppGroupConstants.recordingLevelKey)
        defaults.synchronize()
        DarwinNotify.post(AppGroupConstants.noteResultReady)
    }

    public func publishError(_ message: String) {
        defaults.set(message, forKey: AppGroupConstants.lastErrorKey)
        defaults.set(0 as Float, forKey: AppGroupConstants.recordingLevelKey)
        defaults.synchronize()
        DarwinNotify.post(AppGroupConstants.noteResultReady)
    }

    public func consumeResult() -> (id: String, text: String)? {
        guard let id = defaults.string(forKey: AppGroupConstants.lastResultIDKey),
              let text = defaults.string(forKey: AppGroupConstants.lastResultTextKey),
              !id.isEmpty else { return nil }
        defaults.removeObject(forKey: AppGroupConstants.lastResultIDKey)
        defaults.removeObject(forKey: AppGroupConstants.lastResultTextKey)
        defaults.synchronize()
        return (id, text)
    }

    public var lastError: String? {
        defaults.string(forKey: AppGroupConstants.lastErrorKey)
    }

    public func clearError() {
        defaults.removeObject(forKey: AppGroupConstants.lastErrorKey)
        defaults.synchronize()
    }
}
