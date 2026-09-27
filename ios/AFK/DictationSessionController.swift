import AVFoundation
import Combine
import Foundation
import UIKit

/// Host side of keyboard dictation (Wispr Flow / Typeless model).
///
/// A session starts the mic engine **once, while AFK is foreground**, and keeps it running
/// ("hot mic", orange indicator on). iOS keeps a recording app alive in the background, but
/// refuses to *start* a mixable recording from the background (`cannotStartRecording`), which
/// is why starting capture per keyboard tap failed once the user left AFK. Keyboard start/stop
/// now only arm/disarm which buffers are kept → STT → App Group result.
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
    /// Session mic engine is running (keyboard can dictate from any app).
    @Published var micLive = false
    /// Session was (re)started from the keyboard CTA — show "swipe back" hint.
    @Published var openedFromKeyboard = false

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
    private var observers: [NSObjectProtocol] = []
    private var darwinObservers: [NSObjectProtocol] = []
    private var starting = false
    /// User tapped End while foreground — don't auto-start again until AFK re-enters foreground.
    private var suppressAutoStart = false

    init() {
        // A fresh process never has a running engine; drop state left by a killed host so
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
            self?.handleEngineLost(reason: "Audio route changed")
        }

        darwinObservers.append(DarwinNotify.observe(AppGroupConstants.noteStartRecording) { [weak self] in
            Task { @MainActor in self?.pollKeyboardCommand() }
        })
        darwinObservers.append(DarwinNotify.observe(AppGroupConstants.noteStopRecording) { [weak self] in
            Task { @MainActor in self?.pollKeyboardCommand() }
        })
        // Backstop for a missed Darwin notify; runs whenever the process is alive (hot mic keeps it so).
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
            Task { @MainActor in self?.handleEngineLost(reason: "Audio services reset") }
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

    /// Start (or revive) the session mic. Must run while AFK is foreground.
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
            try capture.startEngine()
        } catch {
            micLive = false
            fail(error.localizedDescription, status: "Mic failed to start")
            if isSessionActive { publishHeartbeat(flush: true) }
            return
        }
        micLive = true
        // Backup assertion only; the running mic engine is what keeps AFK alive in the background.
        try? keepalive.start()

        isSessionActive = true
        relay.isSessionActive = true
        extendSession()
        startTimers()
        publishHeartbeat(flush: true)
        setStatus("Mic ready · dictate from the AFK keyboard")
    }

    func endSession() {
        if isRecording { _ = capture.disarm() }
        isRecording = false
        relay.isRecording = false
        sessionTimer?.invalidate()
        sessionTimer = nil
        heartbeat?.cancel()
        heartbeat = nil
        capture.stopEngine()
        keepalive.stop()
        micLive = false
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

    /// Host became foreground: the one moment iOS allows (re)starting the mic.
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

    /// Host UI "Resume mic" (foreground).
    func resumeMic() {
        Task { await ensureSessionLive() }
    }

    private func ensureSessionLive() async {
        if isSessionActive, capture.isRunning, capture.isDeliveringAudio {
            micLive = true
            try? keepalive.start()
            extendSession()
            publishHeartbeat(flush: true)
            return
        }
        if isSessionActive { capture.stopEngine() }
        await beginSession()
    }

    /// Idle timeout: each dictation / foreground visit pushes expiry out again.
    private func extendSession() {
        let minutes = max(1, settings.sessionMinutes)
        relay.sessionExpiresAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    private func startTimers() {
        sessionTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sessionTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sessionTimer = timer

        // Heartbeat on its own queue so it keeps flowing even if the main thread is busy.
        heartbeat?.cancel()
        let hb = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        hb.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        let relay = self.relay
        let capture = self.capture
        hb.setEventHandler {
            relay.touchHostHeartbeat(alive: true, micLive: capture.isDeliveringAudio)
        }
        hb.resume()
        heartbeat = hb
    }

    private func sessionTick() {
        guard isSessionActive else { return }
        let live = capture.isRunning && capture.isDeliveringAudio
        if live != micLive {
            micLive = live
            if !live { handleEngineLost(reason: "Mic stopped") }
        }
        guard !isRecording, let exp = relay.sessionExpiresAt else { return }
        let left = Int(exp.timeIntervalSinceNow)
        if left <= 0 {
            endSession()
            setStatus("Session ended after \(max(1, settings.sessionMinutes)) min idle")
        } else if left % 60 == 0, micLive {
            setStatus("Mic ready · ends after \(left / 60) min idle")
        }
    }

    private func publishHeartbeat(flush: Bool) {
        relay.touchHostHeartbeat(alive: true, micLive: capture.isDeliveringAudio, flush: flush)
    }

    // MARK: - Mic loss / recovery

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard isSessionActive else { return }
        switch type {
        case .began:
            if isRecording { Task { await stopRecordingAndTranscribe() } }
            micLive = false
            setStatus("Mic interrupted")
            publishHeartbeat(flush: true)
        case .ended:
            recoverMic()
        default:
            break
        }
    }

    private func handleEngineLost(reason: String) {
        guard isSessionActive else { return }
        if isRecording { Task { await stopRecordingAndTranscribe() } }
        recoverMic(reason: reason)
    }

    /// Try to restart the engine. Succeeds in the foreground; in the background iOS usually
    /// refuses (`cannotStartRecording`) and the keyboard shows "Mic paused — open AFK once".
    private func recoverMic(reason: String = "Mic interrupted") {
        guard isSessionActive else { return }
        capture.stopEngine()
        do {
            try capture.startEngine()
            try? keepalive.start()
            micLive = true
            setStatus("Mic ready · dictate from the AFK keyboard")
        } catch {
            micLive = false
            setStatus("\(reason) — open AFK once to resume mic")
        }
        publishHeartbeat(flush: true)
    }

    // MARK: - Keyboard commands

    private func pollKeyboardCommand() {
        guard let pending = relay.consumeCommand() else { return }
        switch pending.command {
        case .start:
            Task { await startRecordingFromKeyboard() }
        case .stop:
            Task { await stopRecordingFromKeyboard() }
        }
    }

    private func startRecordingFromKeyboard() async {
        guard isSessionActive else {
            relay.publishError("Open AFK once to start a session.")
            setStatus("No active session")
            return
        }
        do {
            try await startRecording()
        } catch {
            relay.publishError(error.localizedDescription)
            setStatus(error.localizedDescription)
        }
    }

    private func stopRecordingFromKeyboard() async {
        guard isRecording else {
            // Start never took (or a quick tap raced it) — unblock the keyboard's "Transcribing…".
            relay.publishError("Nothing recorded — tap the mic, speak, then tap again")
            return
        }
        await stopRecordingAndTranscribe()
    }

    // MARK: - Record / transcribe

    func startRecording() async throws {
        errorMessage = nil
        if isRecording { return }
        if !isSessionActive || !capture.isRunning {
            // Works in the foreground; from the background iOS refuses → `.needsForeground`.
            await ensureSessionLive()
        }
        guard capture.isRunning, capture.arm() else {
            micLive = false
            publishHeartbeat(flush: true)
            throw AudioCapture.CaptureError.needsForeground
        }
        isRecording = true
        relay.isRecording = true
        extendSession()
        setStatus("Recording…")
    }

    func stopRecordingAndTranscribe() async {
        guard isRecording else { return }
        let pcm = capture.disarm()
        isRecording = false
        relay.isRecording = false
        relay.recordingLevel = 0
        level = 0
        extendSession()
        setStatus("Transcribing…")

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
            setStatus(micLive ? "Mic ready · dictate from the AFK keyboard" : "Ready")
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
