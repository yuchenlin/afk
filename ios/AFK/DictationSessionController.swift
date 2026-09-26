import AVFoundation
import Combine
import Foundation
import UIKit

/// Keeps a background-capable dictation "session" alive and handles record → STT → App Group.
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
    @Published var keepaliveRunning = false

    private let relay = SessionRelay.shared
    private let capture = AudioCapture()
    private let keepalive = SessionKeepalive()
    private let mock = MockSpeechProvider()
    private let grok = GrokBatchSpeechClient()
    private let polisher = SimplePolisher()
    private var sessionTimer: Timer?
    private var commandPollTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        syncFromRelay()
        capture.onLevel = { [weak self] level in
            Task { @MainActor in
                self?.level = level
                self?.relay.recordingLevel = level
            }
        }
        observers.append(DarwinNotify.observe(AppGroupConstants.noteStartRecording) { [weak self] in
            Task { @MainActor in self?.pollKeyboardCommand() }
        })
        observers.append(DarwinNotify.observe(AppGroupConstants.noteStopRecording) { [weak self] in
            Task { @MainActor in self?.pollKeyboardCommand() }
        })
        observers.append(DarwinNotify.observe(AppGroupConstants.noteOpenHost) { [weak self] in
            Task { @MainActor in
                // Best-effort: only runs if host is already awake.
                self?.status = "Keyboard asked to open AFK"
                self?.relay.statusMessage = self?.status ?? ""
            }
        })
        // Always poll lightly so a missed Darwin notify still lands while the app is alive.
        commandPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollKeyboardCommand() }
        }
        // Ensure poll timer fires in common run-loop modes (scroll / tracking).
        if let commandPollTimer {
            RunLoop.main.add(commandPollTimer, forMode: .common)
        }
        Task { await refreshMicPermission() }
    }

    deinit {
        observers.forEach { DarwinNotify.stop($0) }
        commandPollTimer?.invalidate()
    }

    func syncFromRelay() {
        isSessionActive = relay.isSessionActive
        isRecording = relay.isRecording
        if let exp = relay.sessionExpiresAt, exp < Date() {
            endSession()
        }
    }

    func refreshMicPermission() async {
        micGranted = await capture.requestPermission()
    }

    func saveSettings() {
        settings.save()
        if isSessionActive {
            beginSession(restartTimerOnly: true)
        }
    }

    func beginSession(restartTimerOnly: Bool = false) {
        let minutes = max(1, settings.sessionMinutes)
        let expires = Date().addingTimeInterval(TimeInterval(minutes * 60))
        relay.sessionExpiresAt = expires
        relay.isSessionActive = true
        isSessionActive = true
        status = "Session active · \(minutes) min"
        relay.statusMessage = status

        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.relay.touchHostHeartbeat(alive: true)
                if let exp = self.relay.sessionExpiresAt {
                    let left = Int(exp.timeIntervalSinceNow)
                    if left <= 0 {
                        self.endSession()
                    } else if left % 30 == 0 {
                        self.status = "Session · \(left / 60)m \(left % 60)s left"
                        self.relay.statusMessage = self.status
                    }
                }
            }
        }
        if let sessionTimer {
            RunLoop.main.add(sessionTimer, forMode: .common)
        }

        // Silent looping audio is what actually keeps us unsuspended under UIBackgroundModes:audio.
        startKeepaliveIfNeeded()
        relay.touchHostHeartbeat(alive: true)

        if !restartTimerOnly {
            // Soft keepalive beep intentionally omitted — SessionKeepalive is the real assertion.
        }
    }

    func endSession() {
        if isRecording {
            Task { await stopRecordingAndTranscribe() }
        }
        sessionTimer?.invalidate()
        sessionTimer = nil
        keepalive.stop()
        keepaliveRunning = false
        relay.clearHostHeartbeat()
        relay.isSessionActive = false
        relay.sessionExpiresAt = nil
        relay.recordingLevel = 0
        isSessionActive = false
        status = "Session ended"
        relay.statusMessage = status
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func toggleSession() {
        if isSessionActive { endSession() } else { beginSession() }
    }

    /// Deep link / URL scheme entry (`afk://wake`, `afk://session`, `afk://record`).
    func handleOpenURL(_ url: URL) {
        guard url.scheme == AppGroupConstants.urlScheme else { return }
        let host = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        if !isSessionActive {
            beginSession()
        }
        status = "Session ready for keyboard"
        relay.statusMessage = status
        // Drain any keyboard command that was posted while we were suspended.
        pollKeyboardCommand()
        if host == AppGroupConstants.urlHostRecord, !isRecording {
            Task { try? await startRecordingFromKeyboard() }
        }
    }

    private func startKeepaliveIfNeeded() {
        do {
            try keepalive.start()
            keepaliveRunning = true
            // Clear prior failure so UI never shows green "on" + red failed together.
            if errorMessage?.hasPrefix("Background audio keepalive failed:") == true {
                errorMessage = nil
            }
            if status.hasPrefix("Keepalive failed") {
                let minutes = max(1, settings.sessionMinutes)
                status = "Session active · \(minutes) min"
                relay.statusMessage = status
            }
        } catch {
            keepaliveRunning = false
            let ns = error as NSError
            let detail: String
            if ns.domain == NSOSStatusErrorDomain, ns.code == 560557684 {
                detail = "CannotInterruptOthers (!int) — session was non-mixable in background"
            } else {
                detail = error.localizedDescription
            }
            errorMessage = "Background audio keepalive failed: \(detail)"
            status = "Keepalive failed — stay in AFK"
            relay.statusMessage = status
        }
    }

    private func pollKeyboardCommand() {
        guard let pending = relay.consumeCommand() else { return }
        handleKeyboardCommand(pending.command)
    }

    private func handleKeyboardCommand(_ command: SessionRelay.Command) {
        switch command {
        case .start:
            Task { try? await startRecordingFromKeyboard() }
        case .stop:
            Task { await stopRecordingAndTranscribe() }
        }
    }

    func startRecordingFromKeyboard() async throws {
        guard isSessionActive || relay.isSessionActive else {
            relay.publishError("Start a dictation session in the AFK app first.")
            status = "No active session"
            relay.statusMessage = status
            return
        }
        if !isSessionActive { beginSession() }
        try await startRecording()
    }

    func startRecording() async throws {
        errorMessage = nil
        if !micGranted {
            await refreshMicPermission()
            guard micGranted else { throw AudioCapture.CaptureError.noPermission }
        }
        if !isSessionActive { beginSession() }

        // Pause keepalive playback so AVAudioEngine can own the input.
        // Leave the mixable AVAudioSession active — do not deactivate.
        // Recording itself asserts UIBackgroundModes:audio once the engine starts.
        keepalive.pauseForCapture()
        keepaliveRunning = false

        do {
            try capture.start()
        } catch {
            // Capture failed (often while backgrounded) — restore keepalive immediately
            // so the host is not left without a background assertion.
            startKeepaliveIfNeeded()
            throw error
        }
        isRecording = true
        relay.isRecording = true
        relay.touchHostHeartbeat(alive: true)
        status = "Recording…"
        relay.statusMessage = status
    }

    func stopRecordingAndTranscribe() async {
        guard isRecording || capture.isRecording else { return }
        let pcm = capture.stop()
        isRecording = false
        relay.isRecording = false
        relay.recordingLevel = 0
        level = 0
        status = "Transcribing…"
        relay.statusMessage = status

        // Resume keepalive so the session stays unsuspended for the next utterance.
        if isSessionActive || relay.isSessionActive {
            startKeepaliveIfNeeded()
            relay.touchHostHeartbeat(alive: true)
        }

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
                status = "Polishing…"
                relay.statusMessage = status
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
            status = "Ready"
            relay.statusMessage = status
            UIPasteboard.general.string = text
        } catch {
            errorMessage = error.localizedDescription
            status = "Error"
            relay.statusMessage = status
            relay.publishError(error.localizedDescription)
        }
    }
}
