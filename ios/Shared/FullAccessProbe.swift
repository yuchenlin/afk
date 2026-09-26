import Foundation

/// Detects App Group + keyboard Full Access.
///
/// `UserDefaults(suiteName:)` is **not** a valid Full Access check — it returns a
/// non-nil object even when the keyboard lacks Full Access. Use:
/// 1. `UIInputViewController.hasFullAccess` in the keyboard target
/// 2. `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
/// 3. A read/write probe + host↔keyboard challenge/echo via the App Group suite
public enum FullAccessProbe {
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConstants.suiteName)
    }

    /// True when this process can open the App Group container (host always; keyboard only with Full Access + entitlement).
    public static var canOpenContainer: Bool {
        containerURL != nil
    }

    /// Live App Group suite when the container is available. Prefer this over a
    /// `SessionRelay` captured before Full Access was enabled (keyboard process).
    public static func sharedSuiteDefaults() -> UserDefaults? {
        guard canOpenContainer else { return nil }
        return UserDefaults(suiteName: AppGroupConstants.suiteName)
    }

    /// Same-process write/read against the App Group suite. Useful but not sufficient alone in the keyboard
    /// (a non-shared fallback store can still round-trip). Prefer combining with `canOpenContainer` / `hasFullAccess`.
    @discardableResult
    public static func readWriteProbe(defaults: UserDefaults) -> Bool {
        let token = "probe-\(UUID().uuidString)"
        defaults.set(token, forKey: AppGroupConstants.fullAccessProbeKey)
        defaults.synchronize()
        let ok = defaults.string(forKey: AppGroupConstants.fullAccessProbeKey) == token
        return ok
    }

    /// Host: publish a challenge the keyboard must echo after Full Access is confirmed.
    public static func publishHostChallenge(defaults: UserDefaults = SessionRelay.shared.defaults) {
        let token = "chal-\(UUID().uuidString)"
        defaults.set(token, forKey: AppGroupConstants.fullAccessHostChallengeKey)
        defaults.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.fullAccessHostChallengeAtKey)
        defaults.synchronize()
        DarwinNotify.post(AppGroupConstants.noteFullAccessChanged)
    }

    /// Keyboard: when `hasFullAccess` is true and the container opens, echo the host challenge and mark reported.
    public static func reportFromKeyboard(hasFullAccess: Bool, defaults: UserDefaults = SessionRelay.shared.defaults) {
        // Re-open the suite when the container is available so a keyboard that was
        // launched *before* Full Access still writes into the host-visible store.
        SessionRelay.shared.rebindAppGroupIfNeeded()
        let store = sharedSuiteDefaults() ?? defaults

        guard hasFullAccess, canOpenContainer else {
            // Without the container we cannot reach the host suite — leave host state alone.
            guard canOpenContainer || SessionRelay.shared.usesAppGroup else {
                DarwinNotify.post(AppGroupConstants.noteFullAccessChanged)
                return
            }
            store.set(false, forKey: AppGroupConstants.fullAccessKeyboardReportedKey)
            store.removeObject(forKey: AppGroupConstants.fullAccessKeyboardEchoKey)
            store.synchronize()
            DarwinNotify.post(AppGroupConstants.noteFullAccessChanged)
            return
        }
        _ = readWriteProbe(defaults: store)
        if let challenge = store.string(forKey: AppGroupConstants.fullAccessHostChallengeKey), !challenge.isEmpty {
            store.set(challenge, forKey: AppGroupConstants.fullAccessKeyboardEchoKey)
        }
        store.set(true, forKey: AppGroupConstants.fullAccessKeyboardReportedKey)
        store.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.fullAccessKeyboardReportedAtKey)
        store.synchronize()
        DarwinNotify.post(AppGroupConstants.noteFullAccessChanged)
    }

    public enum HostStatus: Equatable {
        case appGroupMissing
        case waitingForKeyboard
        case configured
        case keyboardReportedOff

        public var label: String {
            switch self {
            case .appGroupMissing: return "App Group not available — check Signing & App Groups"
            case .waitingForKeyboard: return "Not confirmed yet — open any text field and switch to AFK Keyboard once"
            case .configured: return "Configured (Full Access + App Group)"
            case .keyboardReportedOff: return "Keyboard reported Full Access off — open AFK Keyboard once after enabling"
            }
        }

        public var isOK: Bool { self == .configured }
    }

    /// Host-side status for Setup UI.
    ///
    /// A *pending* host challenge (Recheck / Setup appear) must **not** demote an
    /// already-confirmed Full Access report to `.waitingForKeyboard`. The keyboard
    /// only echoes when it next appears; until then `echo != challenge` is expected
    /// and Recheck would always look broken after a successful confirm.
    public static func hostStatus(defaults: UserDefaults = SessionRelay.shared.defaults) -> HostStatus {
        guard canOpenContainer, SessionRelay.shared.usesAppGroup else {
            return .appGroupMissing
        }
        let reported = defaults.object(forKey: AppGroupConstants.fullAccessKeyboardReportedKey) != nil
        let flagged = defaults.bool(forKey: AppGroupConstants.fullAccessKeyboardReportedKey)
        if !reported {
            return .waitingForKeyboard
        }
        guard flagged else { return .keyboardReportedOff }

        // Keyboard reported on (written into the App Group suite) is sufficient
        // cross-process proof. Do not require echo == latest challenge — Recheck
        // rotates the challenge and would otherwise always fail until the keyboard
        // is opened again.
        return .configured
    }
}
