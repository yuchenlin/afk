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

    private let relay = SessionRelay.shared
    private let capture = AudioCapture()
    private let mock = MockSpeechProvider()
    private let grok = GrokBatchSpeechClient()
    private let polisher = SimplePolisher()
    private var sessionTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        syncFromRelay()
        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        observers.append(DarwinNotify.observe(AppGroupConstants.noteStartRecording) { [weak self] in
            Task { @MainActor in try? await self?.startRecordingFromKeyboard() }
        })
        observers.append(DarwinNotify.observe(AppGroupConstants.noteStopRecording) { [weak self] in
            Task { @MainActor in await self?.stopRecordingAndTranscribe() }
        })
        Task { await refreshMicPermission() }
    }

    deinit {
        observers.forEach { DarwinNotify.stop($0) }
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
            // Refresh expiry window if session length changed.
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

        // Activate audio session so background mode can keep the orange mic indicator.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            errorMessage = "Audio session: \(error.localizedDescription)"
        }

        if !restartTimerOnly {
            // Soft keepalive beep intentionally omitted.
        }
    }

    func endSession() {
        if isRecording {
            Task { await stopRecordingAndTranscribe() }
        }
        sessionTimer?.invalidate()
        sessionTimer = nil
        relay.isSessionActive = false
        relay.sessionExpiresAt = nil
        isSessionActive = false
        status = "Session ended"
        relay.statusMessage = status
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func toggleSession() {
        if isSessionActive { endSession() } else { beginSession() }
    }

    func startRecordingFromKeyboard() async throws {
        guard isSessionActive || relay.isSessionActive else {
            relay.publishError("Start a dictation session in the AFK app first.")
            status = "No active session"
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
        try capture.start()
        isRecording = true
        relay.isRecording = true
        status = "Recording…"
        relay.statusMessage = status
    }

    func stopRecordingAndTranscribe() async {
        guard isRecording || capture.isRecording else { return }
        let pcm = capture.stop()
        isRecording = false
        relay.isRecording = false
        level = 0
        status = "Transcribing…"
        relay.statusMessage = status

        do {
            let settings = self.settings
            let apiKey = KeychainStore.readAPIKey()
            let speech: SpeechTranscribing = settings.useMockSTT ? mock : grok
            var text = try await speech.transcribe(
                pcm16: pcm,
                sampleRate: AudioCapture.sampleRate,
                model: settings.speechModel,
                apiKey: apiKey
            )
            if settings.polishEnabled, !settings.useMockSTT, apiKey != nil {
                status = "Polishing…"
                relay.statusMessage = status
                let polish: TextPolishing = polisher
                if let polished = try? await polish.polish(text, model: settings.polishModel, apiKey: apiKey),
                   !polished.isEmpty {
                    text = polished
                }
            } else if settings.polishEnabled, settings.useMockSTT {
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
