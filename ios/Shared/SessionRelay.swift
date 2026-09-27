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
        /// Close the mic and drop the utterance (keyboard dismissed mid-hold).
        case cancel
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
        case .stop, .cancel: DarwinNotify.post(AppGroupConstants.noteStopRecording)
        }
        return id
    }

    /// Keyboard: "still here" while an utterance is open, so the host never leaves the
    /// mic open after the keyboard vanishes without sending stop. `flush` pushes it to the
    /// host process at once (callers throttle it).
    public func touchKeyboardPing(flush: Bool) {
        defaults.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.keyboardPingAtKey)
        if flush { defaults.synchronize() }
    }

    /// Host: seconds since the keyboard last pinged (`.infinity` if never).
    public var secondsSinceKeyboardPing: TimeInterval {
        let t = defaults.double(forKey: AppGroupConstants.keyboardPingAtKey)
        guard t > 0 else { return .infinity }
        return Date().timeIntervalSince1970 - t
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
        let at = Date().timeIntervalSince1970
        defaults.set(text, forKey: AppGroupConstants.lastResultTextKey)
        defaults.set(id, forKey: AppGroupConstants.lastResultIDKey)
        defaults.set(at, forKey: AppGroupConstants.lastResultAtKey)
        defaults.removeObject(forKey: AppGroupConstants.lastErrorKey)
        // New utterance must be insertable even if a prior id was acknowledged.
        // (lastInsertedID stays — peek compares against it.)
        defaults.set(0 as Float, forKey: AppGroupConstants.recordingLevelKey)
        defaults.synchronize()
        writePendingResultFile(id: id, text: text, at: at)
        DarwinNotify.post(AppGroupConstants.noteResultReady)
    }

    public func publishError(_ message: String) {
        defaults.set(message, forKey: AppGroupConstants.lastErrorKey)
        defaults.set(0 as Float, forKey: AppGroupConstants.recordingLevelKey)
        defaults.synchronize()
        DarwinNotify.post(AppGroupConstants.noteResultReady)
    }

    /// Read the pending result without deleting it. Returns nil once `acknowledgeResult`
    /// has recorded the same id as inserted. Falls back to the App Group file when
    /// UserDefaults has not yet mirrored the host write into this process.
    public func peekResult() -> (id: String, text: String)? {
        defaults.synchronize()
        let inserted = defaults.string(forKey: AppGroupConstants.lastInsertedResultIDKey)
        if let id = defaults.string(forKey: AppGroupConstants.lastResultIDKey),
           let text = defaults.string(forKey: AppGroupConstants.lastResultTextKey),
           !id.isEmpty, !text.isEmpty, id != inserted {
            return (id, text)
        }
        // Cross-process UD lag / extension cold start — try the durable file.
        if let file = readPendingResultFile(), file.id != inserted, !file.text.isEmpty {
            // Mirror into UD so subsequent peeks/polls are cheap.
            defaults.set(file.text, forKey: AppGroupConstants.lastResultTextKey)
            defaults.set(file.id, forKey: AppGroupConstants.lastResultIDKey)
            defaults.set(file.at, forKey: AppGroupConstants.lastResultAtKey)
            defaults.synchronize()
            return (file.id, file.text)
        }
        return nil
    }

    /// Mark a result as inserted. Keeps text/id in UD+file for diagnostics, but peek
    /// will skip it. Never silently deletes a successful STT before the keyboard acks.
    public func acknowledgeResult(id: String) {
        defaults.set(id, forKey: AppGroupConstants.lastInsertedResultIDKey)
        // Clear the "pending" markers so chrome stops showing Transcribing, but leave
        // a copy in the file until the next publish overwrites it.
        if defaults.string(forKey: AppGroupConstants.lastResultIDKey) == id {
            defaults.removeObject(forKey: AppGroupConstants.lastResultIDKey)
            defaults.removeObject(forKey: AppGroupConstants.lastResultTextKey)
            defaults.removeObject(forKey: AppGroupConstants.lastResultAtKey)
        }
        defaults.synchronize()
        clearPendingResultFile(matching: id)
    }

    /// Peek + acknowledge in one step. Prefer peek/acknowledge when insert may fail.
    public func consumeResult() -> (id: String, text: String)? {
        guard let result = peekResult() else { return nil }
        acknowledgeResult(id: result.id)
        return result
    }

    // MARK: - Durable pending-result file (App Group container)

    private var pendingResultFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(AppGroupConstants.pendingResultFileName)
    }

    private func writePendingResultFile(id: String, text: String, at: TimeInterval) {
        guard let url = pendingResultFileURL else { return }
        let payload: [String: Any] = ["id": id, "text": text, "at": at]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func readPendingResultFile() -> (id: String, text: String, at: TimeInterval)? {
        guard let url = pendingResultFileURL,
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty,
              let text = obj["text"] as? String, !text.isEmpty else { return nil }
        let at = (obj["at"] as? TimeInterval) ?? 0
        return (id, text, at)
    }

    private func clearPendingResultFile(matching id: String) {
        guard let url = pendingResultFileURL else { return }
        if let current = readPendingResultFile(), current.id != id { return }
        try? FileManager.default.removeItem(at: url)
    }

    public var lastError: String? {
        defaults.string(forKey: AppGroupConstants.lastErrorKey)
    }

    public func clearError() {
        defaults.removeObject(forKey: AppGroupConstants.lastErrorKey)
        defaults.synchronize()
    }

    /// Host: mark process as alive (1 Hz background-queue heartbeat).
    /// `micBlocked` = the host has no armed mic engine (iOS stopped it or refused to start
    /// it), so the next hold needs one trip to AFK. Posts `noteSessionChanged` only when it flips.
    /// `flush` forces the shared suite out so the keyboard process sees it at once.
    public func touchHostHeartbeat(alive: Bool = true, micBlocked: Bool, flush: Bool = false) {
        let wasBlocked = defaults.bool(forKey: AppGroupConstants.hostMicBlockedKey)
        defaults.set(alive, forKey: AppGroupConstants.hostAliveKey)
        defaults.set(micBlocked, forKey: AppGroupConstants.hostMicBlockedKey)
        defaults.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.hostHeartbeatAtKey)
        if flush || wasBlocked != micBlocked { defaults.synchronize() }
        if wasBlocked != micBlocked { DarwinNotify.post(AppGroupConstants.noteSessionChanged) }
    }

    public func clearHostHeartbeat() {
        defaults.set(false, forKey: AppGroupConstants.hostAliveKey)
        defaults.set(false, forKey: AppGroupConstants.hostMicBlockedKey)
        defaults.set(0.0, forKey: AppGroupConstants.hostHeartbeatAtKey)
        defaults.synchronize()
    }

    /// Keyboard: the host has no armed mic engine (last heartbeat said so).
    public var hostMicBlocked: Bool {
        defaults.bool(forKey: AppGroupConstants.hostMicBlockedKey)
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

/// In-keyboard call-to-action when the host cannot take a keyboard hold.
/// Mic never opens the host; only a deliberate tap on this CTA may.
public enum HostCTA: Equatable {
    /// No session yet.
    case startSession
    /// Session flag set but host heartbeat is gone (suspended / killed).
    case sessionExpired
    /// Host alive but iOS stopped its muted mic engine (call, Siri, route change) — restarting
    /// it needs one foreground visit.
    case recoverHost

    public var title: String {
        switch self {
        case .startSession: return "Open AFK once to start session"
        case .sessionExpired: return "Session paused — open AFK once"
        case .recoverHost: return "Mic off — open AFK once to turn it on"
        }
    }

    /// All CTAs (re)start the session in the foreground, then the user swipes back.
    public var urlPath: String { AppGroupConstants.urlHostSession }
}

