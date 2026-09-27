import Foundation

/// Read/write shared session + result state via the App Group suite.
public final class SessionRelay {
    public static let shared = SessionRelay()

    private let suiteName: String
    private var _defaults: UserDefaults
    private var _usesAppGroup: Bool

    /// App Group suite when available. May rebind after Full Access is enabled mid-lifetime
    /// (keyboard often starts without FA, then Settings toggles it on).
    public var defaults: UserDefaults {
        rebindAppGroupIfNeeded()
        return _defaults
    }

    /// False when the App Group container is missing (entitlement / provisioning / no Full Access).
    public var usesAppGroup: Bool {
        rebindAppGroupIfNeeded()
        return _usesAppGroup
    }

    public enum Command: String {
        case start
        case stop
    }

    /// Keyboard view of host liveness from App Group heartbeat.
    public enum HostHealth: Equatable {
        /// Heartbeat within readyAge (default 4s).
        case ready
        /// Heartbeat stale but not dead (4–10s) — optimistic command OK.
        case degraded
        /// No heartbeat / hostAlive false / older than downAge.
        case down
    }

    public init(suiteName: String = AppGroupConstants.suiteName) {
        self.suiteName = suiteName
        let resolved = Self.resolve(suiteName: suiteName)
        self._defaults = resolved.defaults
        self._usesAppGroup = resolved.usesAppGroup
    }

    private static func resolve(suiteName: String) -> (defaults: UserDefaults, usesAppGroup: Bool) {
        let containerOK = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil
        if containerOK, let d = UserDefaults(suiteName: suiteName) {
            return (d, true)
        }
        if let d = UserDefaults(suiteName: suiteName) {
            // Keyboard without Full Access: suite object may exist but container is nil.
            // Prefer the suite anyway so in-process state works; sharing with host will fail.
            return (d, false)
        }
        return (.standard, false)
    }

    /// Call when Full Access / container may have become available since init.
    @discardableResult
    public func rebindAppGroupIfNeeded() -> Bool {
        let resolved = Self.resolve(suiteName: suiteName)
        guard resolved.usesAppGroup else { return _usesAppGroup }
        if !_usesAppGroup {
            _defaults = resolved.defaults
            _usesAppGroup = true
        }
        return true
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
    /// Drops commands older than `maxAge` so a start posted while the host was dead
    /// does not fire minutes later when the user opens AFK for an unrelated reason.
    public func consumeCommand(maxAge: TimeInterval = 8) -> (id: String, command: Command)? {
        guard let id = defaults.string(forKey: AppGroupConstants.commandIDKey), !id.isEmpty else {
            return nil
        }
        let last = defaults.string(forKey: AppGroupConstants.lastConsumedCommandIDKey)
        guard id != last else { return nil }
        let at = defaults.double(forKey: AppGroupConstants.commandAtKey)
        if at > 0, Date().timeIntervalSince1970 - at > maxAge {
            defaults.set(id, forKey: AppGroupConstants.lastConsumedCommandIDKey)
            defaults.removeObject(forKey: AppGroupConstants.commandActionKey)
            defaults.removeObject(forKey: AppGroupConstants.commandIDKey)
            defaults.synchronize()
            return nil
        }
        guard let raw = defaults.string(forKey: AppGroupConstants.commandActionKey),
              let command = Command(rawValue: raw) else {
            return nil
        }
        defaults.set(id, forKey: AppGroupConstants.lastConsumedCommandIDKey)
        defaults.removeObject(forKey: AppGroupConstants.commandActionKey)
        defaults.synchronize()
        return (id, command)
    }

    /// Keyboard: abandon a start/stop that the host never consumed.
    public func clearPendingCommand() {
        defaults.removeObject(forKey: AppGroupConstants.commandActionKey)
        defaults.removeObject(forKey: AppGroupConstants.commandIDKey)
        defaults.removeObject(forKey: AppGroupConstants.commandAtKey)
        defaults.synchronize()
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

    /// Host: mark process as alive (1 Hz background-queue heartbeat).
    /// `micLive` = session mic engine is delivering buffers, so a keyboard start will work
    /// without foregrounding the host. Posts `noteSessionChanged` only when it flips.
    /// `flush` forces the shared suite out so the keyboard process sees it at once.
    public func touchHostHeartbeat(alive: Bool = true, micLive: Bool, flush: Bool = false) {
        let wasLive = defaults.bool(forKey: AppGroupConstants.hostMicLiveKey)
        defaults.set(alive, forKey: AppGroupConstants.hostAliveKey)
        defaults.set(micLive, forKey: AppGroupConstants.hostMicLiveKey)
        defaults.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.hostHeartbeatAtKey)
        if flush || wasLive != micLive { defaults.synchronize() }
        if wasLive != micLive { DarwinNotify.post(AppGroupConstants.noteSessionChanged) }
    }

    public func clearHostHeartbeat() {
        defaults.set(false, forKey: AppGroupConstants.hostAliveKey)
        defaults.set(false, forKey: AppGroupConstants.hostMicLiveKey)
        defaults.set(0.0, forKey: AppGroupConstants.hostHeartbeatAtKey)
        defaults.synchronize()
    }

    /// Keyboard: host's session mic engine is running (last heartbeat said so).
    public var hostMicLive: Bool {
        defaults.bool(forKey: AppGroupConstants.hostMicLiveKey)
    }

    /// Keyboard: true if host wrote a heartbeat within `maxAge` seconds.
    public func isHostHeartbeatFresh(maxAge: TimeInterval = 3.0) -> Bool {
        hostHealth(readyAge: maxAge, downAge: maxAge) == .ready
    }

    /// Graded host liveness for the keyboard CTA / mic gate.
    public func hostHealth(readyAge: TimeInterval = 4.0, downAge: TimeInterval = 10.0) -> HostHealth {
        guard defaults.bool(forKey: AppGroupConstants.hostAliveKey) else { return .down }
        let t = defaults.double(forKey: AppGroupConstants.hostHeartbeatAtKey)
        guard t > 0 else { return .down }
        let age = Date().timeIntervalSince1970 - t
        if age <= readyAge { return .ready }
        if age <= downAge { return .degraded }
        return .down
    }

    public var pendingCommandID: String? {
        defaults.string(forKey: AppGroupConstants.commandIDKey)
    }

    public var lastConsumedCommandID: String? {
        defaults.string(forKey: AppGroupConstants.lastConsumedCommandIDKey)
    }
}

/// In-keyboard call-to-action when the host session mic is not ready.
/// Mic never opens the host; only a deliberate tap on this CTA may.
public enum HostCTA: Equatable {
    /// No session yet.
    case startSession
    /// Session flag set but host heartbeat is gone (suspended / killed).
    case sessionExpired
    /// Host alive but iOS stopped its mic (call, Siri, route change) — needs foreground to restart.
    case recoverHost

    public var title: String {
        switch self {
        case .startSession: return "Open AFK once to start session"
        case .sessionExpired: return "Session paused — open AFK once"
        case .recoverHost: return "Mic paused by iOS — open AFK once"
        }
    }

    /// All CTAs (re)start the session mic in the foreground, then the user swipes back.
    public var urlPath: String { AppGroupConstants.urlHostSession }
}

