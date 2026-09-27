import AVFoundation
import Combine
import Foundation
import os
import UIKit

/// Host side of keyboard dictation: press-and-hold / tap-to-speak.
///
/// iOS will not start mic input while AFK is in the background, but it lets an input engine
/// that is already running keep going. So when a session starts (AFK foreground) the host
/// activates one mixable `.playAndRecord` session with a near-silent loop (`SessionKeepalive`,
/// keeps AFK alive) and **arms** a voice-processing engine whose input is muted at once
/// (`AudioCapture`). Muted input = no audio kept and no orange indicator between utterances.
/// Keyboard start → unmute (orange on only while held); keyboard stop → mute → STT → App Group
/// result. The keyboard never foregrounds AFK.
///
/// If iOS stops the armed engine (call, Siri, audio route change) it cannot be restarted from
/// the background: the heartbeat publishes `micBlocked` and the keyboard shows the
/// "open AFK once" CTA; the next foreground visit re-arms.
@MainActor
final class DictationSessionController: ObservableObject {
    @Published var settings: IOSSettings = .load()
    @Published var isSessionActive = false
    @Published var isRecording = false
    @Published var status = "Idle"
    @Published var lastTranscript = ""
    @Published var level: Float = 0
    @Published var micGranted = false
    @Published var errorMessage: String?
    /// iOS refused the last background mic start; a foreground visit clears it.
    @Published var micBlocked = false
    /// Session was (re)started from the keyboard CTA — show "swipe back" hint.
    @Published var openedFromKeyboard = false

    private enum UtteranceSource { case keyboard, host }

    private let log = Logger(subsystem: "xyz.yuchenlin.afk.ios", category: "dictation")
    private let relay = SessionRelay.shared
    private let capture = AudioCapture()
    private let keepalive = SessionKeepalive()
    private let mock = MockSpeechProvider()
    private let grok = GrokBatchSpeechClient()
    private let polisher = SimplePolisher()
    private var sessionTimer: Timer?
    private var commandPollTimer: Timer?
    private let heartbeatQueue = DispatchQueue(label: "xyz.yuchenlin.afk.heartbeat", qos: .userInitiated)
    private var heartbeat: DispatchSourceTimer?
    private let blockedFlag = LockedFlag()
    private var observers: [NSObjectProtocol] = []
    private var darwinObservers: [NSObjectProtocol] = []
    private var starting = false
    /// User tapped End while foreground — don't auto-start again until AFK re-enters foreground.
    private var suppressAutoStart = false
    private var utteranceSource: UtteranceSource?
    private var utteranceStartedAt: Date?
    private var utteranceID = 0
    private var lastArmAttempt = Date.distantPast

    /// Longest single utterance; the mic closes on its own after this.
    private let maxUtteranceSeconds: TimeInterval = 120
    /// Keyboard pings (flushed ~2 Hz) while an utterance is open; older than this = keyboard gone.
    private let keyboardPingTimeout: TimeInterval = 4

    init() {
        // A fresh process never has a live session; drop state left by a killed host so
        // the keyboard shows the CTA instead of a dead "session on".
        if relay.isSessionActive || relay.isRecording {
            relay.isRecording = false
            relay.isSessionActive = false
            relay.sessionExpiresAt = nil
            relay.clearHostHeartbeat()
        }
        micGranted = AudioCapture.hasPermission

        capture.onLevel = { [weak self] level in
            self?.level = level
            self?.relay.recordingLevel = level
        }
        capture.onEngineStopped = { [weak self] in
            self?.handleEngineStopped()
        }

        darwinObservers.append(DarwinNotify.observe(AppGroupConstants.noteStartRecording) { [weak self] in
            Task { @MainActor in self?.pollKeyboardCommand() }
        })
        darwinObservers.append(DarwinNotify.observe(AppGroupConstants.noteStopRecording) { [weak self] in
            Task { @MainActor in self?.pollKeyboardCommand() }
        })
        // Backstop for a missed Darwin notify; runs whenever the process is alive
        // (the playback keepalive keeps it so during a session).
        let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollKeyboardCommand() }
        }
        RunLoop.main.add(poll, forMode: .common)
        commandPollTimer = poll

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleInterruption(raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suppressAutoStart = false }
        })
    }

    deinit {
        darwinObservers.forEach { DarwinNotify.stop($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        commandPollTimer?.invalidate()
        heartbeat?.cancel()
    }

    func refreshMicPermission() async {
        micGranted = await capture.requestPermission()
    }

    func saveSettings() {
        settings.save()
        if isSessionActive { extendSession() }
    }

    // MARK: - Session lifecycle

    /// Start (or revive) the session in the foreground: audio session + keepalive loop, armed
    /// (muted) mic engine, heartbeat.
    func beginSession() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        errorMessage = nil
        suppressAutoStart = false

        if !micGranted { await refreshMicPermission() }
        guard micGranted else {
            fail("Microphone access is off — allow it in Settings → AFK → Microphone.", status: "Mic permission needed")
            return
        }

        do {
            try keepalive.start()
        } catch {
            fail("Background audio failed to start: \(error.localizedDescription)", status: "Session failed to start")
            return
        }

        isSessionActive = true
        relay.isSessionActive = true
        extendSession()
        startTimers()
        if armMic() { setStatus(readyStatus) }
        publishHeartbeat(flush: true)
    }

    func endSession() {
        if isRecording { cancelRecording(reason: nil) }
        sessionTimer?.invalidate()
        sessionTimer = nil
        heartbeat?.cancel()
        heartbeat = nil
        capture.disarm()
        keepalive.stop()
        setMicBlocked(false)
        openedFromKeyboard = false
        relay.clearHostHeartbeat()
        relay.isSessionActive = false
        relay.sessionExpiresAt = nil
        relay.recordingLevel = 0
        level = 0
        isSessionActive = false
        setStatus("Session ended")
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func toggleSession() {
        if isSessionActive {
            suppressAutoStart = true
            endSession()
        } else {
            Task { await beginSession() }
        }
    }

    /// Deep link from the keyboard CTA (`afk://session`, legacy `afk://wake` / `afk://record`).
    func handleOpenURL(_ url: URL) {
        guard url.scheme == AppGroupConstants.urlScheme else { return }
        openedFromKeyboard = true
        Task {
            await ensureSessionLive()
            pollKeyboardCommand()
        }
    }

    /// Host became foreground: (re)start the session and re-arm the mic if iOS stopped it.
    func noteBecameActive() {
        Task {
            if isSessionActive {
                await ensureSessionLive()
            } else if settings.autoStartSession, !suppressAutoStart,
                      UserDefaults.standard.bool(forKey: "afk.ios.onboardingDone"),
                      AudioCapture.hasPermission {
                await beginSession()
            }
            pollKeyboardCommand()
        }
    }

    private func ensureSessionLive() async {
        guard isSessionActive else {
            await beginSession()
            return
        }
        try? keepalive.start()
        let armed = capture.isArmed || armMic()
        extendSession()
        publishHeartbeat(flush: true)
        if armed, !isRecording { setStatus(readyStatus) }
    }

    private var readyStatus: String {
        "Ready · hold the AFK keyboard mic to talk (mic muted until then)"
    }

    private var appIsActive: Bool { UIApplication.shared.applicationState == .active }

    /// Start the muted engine (foreground only). On failure the keyboard gets the CTA.
    @discardableResult
    private func armMic() -> Bool {
        lastArmAttempt = Date()
        do {
            try capture.arm()
            log.info("mic armed (muted) appActive=\(self.appIsActive)")
            if micBlocked { errorMessage = nil }
            setMicBlocked(false)
            return true
        } catch {
            log.error("mic arm failed appActive=\(self.appIsActive) code=\((error as NSError).code) \(error.localizedDescription, privacy: .public)")
            setMicBlocked(true)
            if appIsActive {
                fail("Mic failed to start: \(error.localizedDescription)", status: "Mic failed to start")
            } else {
                setStatus(blockedStatus)
            }
            publishHeartbeat(flush: true)
            return false
        }
    }

    /// Idle timeout: each dictation / foreground visit pushes expiry out again.
    private func extendSession() {
        let minutes = max(1, settings.sessionMinutes)
        relay.sessionExpiresAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    private func startTimers() {
        sessionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sessionTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sessionTimer = timer

        // Heartbeat on its own queue so it keeps flowing even if the main thread is busy.
        heartbeat?.cancel()
        let hb = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        hb.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        let relay = self.relay
        let blocked = self.blockedFlag
        hb.setEventHandler {
            relay.touchHostHeartbeat(alive: true, micBlocked: blocked.value)
        }
        hb.resume()
        heartbeat = hb
    }

    private func sessionTick() {
        guard isSessionActive else { return }
        if isRecording {
            watchUtterance()
            return
        }
        // The loop keeps AFK running in the background; revive it if iOS stopped it
        // (mixable, so this is allowed from the background).
        if !keepalive.isRunning { try? keepalive.start() }
        if !capture.isArmed {
            if appIsActive {
                if Date().timeIntervalSince(lastArmAttempt) >= 3 { armMic() }
            } else if !micBlocked, !capture.restart() {
                // Engine gone in the background: tell the keyboard before the next hold fails.
                capture.disarm()
                markMicBlocked()
            }
        }
        guard let exp = relay.sessionExpiresAt else { return }
        let left = Int(exp.timeIntervalSinceNow)
        if left <= 0 {
            endSession()
            setStatus("Session ended after \(max(1, settings.sessionMinutes)) min idle")
        }
    }

    /// Close the mic when the keyboard is gone or the utterance runs too long.
    private func watchUtterance() {
        guard let started = utteranceStartedAt else { return }
        if Date().timeIntervalSince(started) >= maxUtteranceSeconds {
            Task { await stopRecordingAndTranscribe() }
            return
        }
        if utteranceSource == .keyboard, relay.secondsSinceKeyboardPing > keyboardPingTimeout {
            cancelRecording(reason: "Keyboard closed — mic turned off")
        }
    }

    private func publishHeartbeat(flush: Bool) {
        relay.touchHostHeartbeat(alive: true, micBlocked: micBlocked, flush: flush)
    }

    private func setMicBlocked(_ blocked: Bool) {
        micBlocked = blocked
        blockedFlag.value = blocked
    }

    // MARK: - Interruptions

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard isSessionActive else { return }
        switch type {
        case .began:
            if let pcm = endUtterance() { Task { await transcribe(pcm) } }
            setStatus("Audio interrupted")
        case .ended:
            try? keepalive.start()
            // Restart in place first; a fresh engine needs the foreground. Otherwise the
            // keyboard gets the CTA.
            if !capture.isArmed, !capture.restart() {
                capture.disarm()
                armMic()
            }
            if capture.isArmed, !isRecording { setStatus(readyStatus) }
        default:
            break
        }
        publishHeartbeat(flush: true)
    }

    private func handleMediaServicesReset() {
        guard isSessionActive else { return }
        if isRecording { cancelRecording(reason: "Audio services reset — try again") }
        capture.disarm()
        keepalive.stop()
        try? keepalive.start()
        armMic()
        publishHeartbeat(flush: true)
    }

    /// The armed engine stopped and would not restart in place. Keep what was said so far.
    /// In the foreground `sessionTick` re-arms (throttled); in the background the keyboard
    /// gets the CTA.
    private func handleEngineStopped() {
        guard isSessionActive else { return }
        log.error("armed engine stopped by iOS appActive=\(self.appIsActive)")
        if let pcm = endUtterance() { Task { await transcribe(pcm) } }
        capture.disarm()
        if !appIsActive { markMicBlocked() }
    }

    private func markMicBlocked() {
        setMicBlocked(true)
        setStatus(blockedStatus)
        publishHeartbeat(flush: true)
    }

    private let blockedStatus = "iOS stopped the mic — open AFK once to turn it back on"

    // MARK: - Keyboard commands

    private func pollKeyboardCommand() {
        guard let pending = relay.consumeCommand() else { return }
        switch pending.command {
        case .start:
            startRecordingFromKeyboard()
        case .stop:
            Task { await stopRecordingFromKeyboard() }
        case .cancel:
            if isRecording { cancelRecording(reason: nil) }
        }
    }

    private func startRecordingFromKeyboard() {
        guard isSessionActive else {
            relay.publishError("Open AFK once to start a session.")
            setStatus("No active session")
            return
        }
        do {
            try startRecording(source: .keyboard)
        } catch {
            relay.publishError(error.localizedDescription)
            setStatus(error.localizedDescription)
        }
    }

    private func stopRecordingFromKeyboard() async {
        guard isRecording else {
            // Start never took — unblock the keyboard's "Transcribing…", but keep a start
            // failure the keyboard has not read yet (it says why).
            if relay.lastError == nil {
                relay.publishError("Nothing recorded — hold the mic while you talk")
            }
            return
        }
        await stopRecordingAndTranscribe()
    }

    // MARK: - Record / transcribe

    /// Host UI record button (AFK is foreground).
    func toggleRecordingFromHost() async {
        if isRecording {
            await stopRecordingAndTranscribe()
            return
        }
        if !isSessionActive { await beginSession() }
        do {
            try startRecording(source: .host)
        } catch {
            fail(error.localizedDescription, status: "Mic failed to start")
        }
    }

    /// Unmute the armed engine for one utterance (works from the background).
    private func startRecording(source: UtteranceSource) throws {
        errorMessage = nil
        if isRecording { return }
        guard isSessionActive else {
            throw AudioCapture.CaptureError.engineStart("Open AFK once to start a session.")
        }
        guard micGranted || AudioCapture.hasPermission else { throw AudioCapture.CaptureError.noPermission }

        if !capture.isArmed {
            capture.disarm()
            guard armMic() else {
                throw appIsActive
                    ? AudioCapture.CaptureError.engineStart("Mic failed to start")
                    : AudioCapture.CaptureError.backgroundStartBlocked
            }
        }
        try capture.open()
        log.info("utterance open source=\(String(describing: source)) appActive=\(self.appIsActive)")

        utteranceID += 1
        let id = utteranceID
        utteranceSource = source
        utteranceStartedAt = Date()
        isRecording = true
        relay.isRecording = true
        publishHeartbeat(flush: true)
        extendSession()
        setStatus("Recording…")

        // The engine reports running but no input arrives: treat it as stopped by iOS.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isRecording, self.utteranceID == id, self.capture.buffersReceived == 0 else { return }
            self.cancelRecording(reason: AudioCapture.CaptureError.backgroundStartBlocked.localizedDescription)
            self.capture.disarm()
            self.armMic()
        }
    }

    /// Close the mic and drop the utterance. `reason` goes to the keyboard as an error.
    private func cancelRecording(reason: String?) {
        guard isRecording else { return }
        capture.close()
        finishUtteranceState()
        if let reason {
            relay.publishError(reason)
            setStatus(reason)
        } else {
            setStatus(readyStatus)
        }
    }

    private func finishUtteranceState() {
        isRecording = false
        relay.isRecording = false
        relay.recordingLevel = 0
        level = 0
        utteranceSource = nil
        utteranceStartedAt = nil
    }

    func stopRecordingAndTranscribe() async {
        guard let pcm = endUtterance() else { return }
        await transcribe(pcm)
    }

    /// Mute and take the utterance PCM now, before any `disarm()` can drop it.
    private func endUtterance() -> Data? {
        guard isRecording else { return nil }
        let buffers = capture.buffersReceived
        let pcm = capture.close()
        log.info("utterance closed bytes=\(pcm.count) buffers=\(buffers) peak=\(AudioCapture.peak(of: pcm)) appActive=\(self.appIsActive)")
        finishUtteranceState()
        extendSession()
        setStatus("Transcribing…")
        return pcm
    }

    private func transcribe(_ pcm: Data) async {
        do {
            // Reload so Keychain / App Group migrations apply even if Settings sheet wasn't opened.
            let settings = IOSSettings.load()
            self.settings = settings
            let apiKey = KeychainStore.readAPIKey()
            // Key present → always live Grok (never Chinese mock). Mock only when
            // explicitly enabled AND no key. Missing key + mock off → clear error.
            let useMock = settings.useMockSTT && apiKey == nil
            if apiKey == nil, !useMock {
                throw SpeechPipelineError.noAPIKey
            }
            let speech: SpeechTranscribing = useMock ? mock : grok
            var text = try await speech.transcribe(
                pcm16: pcm,
                sampleRate: AudioCapture.sampleRate,
                model: settings.speechModel,
                apiKey: apiKey
            )
            if settings.polishEnabled, !useMock, apiKey != nil {
                setStatus("Polishing…")
                let polish: TextPolishing = polisher
                if let polished = try? await polish.polish(text, model: settings.polishModel, apiKey: apiKey),
                   !polished.isEmpty {
                    text = polished
                }
            } else if settings.polishEnabled, useMock {
                text = (try? await mock.polish(text, model: settings.polishModel, apiKey: nil)) ?? text
            }
            lastTranscript = text
            relay.publishResult(text)
            setStatus(isSessionActive ? readyStatus : "Ready")
            UIPasteboard.general.string = text
        } catch {
            errorMessage = error.localizedDescription
            setStatus("Error")
            relay.publishError(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        status = text
        relay.statusMessage = text
    }

    private func fail(_ message: String, status: String) {
        errorMessage = message
        setStatus(status)
    }
}

/// Bool readable from the heartbeat queue.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
