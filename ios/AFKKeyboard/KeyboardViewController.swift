import UIKit

/// AFK Keyboard — Typeless-like voice-first UI; typing via ABC / 中文; host records via App Group.
final class KeyboardViewController: UIInputViewController {
    private var keyboardView: KeyboardView!
    private let relay = SessionRelay.shared
    private var shiftOn = false
    private var needsFullAccessBanner = false
    private var resultObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var awaitingResult = false
    private var lastInsertedResultID: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        hasDictationKey = true

        let kv = KeyboardView(frame: .zero)
        kv.translatesAutoresizingMaskIntoConstraints = false
        kv.delegate = self
        view.addSubview(kv)
        NSLayoutConstraint.activate([
            kv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kv.topAnchor.constraint(equalTo: view.topAnchor),
            kv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            kv.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        keyboardView = kv
        refreshFullAccessState()
        refreshChrome()

        resultObserver = DarwinNotify.observe(AppGroupConstants.noteResultReady) { [weak self] in
            self?.consumeResultIfNeeded()
        }
        sessionObserver = DarwinNotify.observe(AppGroupConstants.noteSessionChanged) { [weak self] in
            self?.refreshChrome()
        }
    }

    deinit {
        if let resultObserver { DarwinNotify.stop(resultObserver) }
        if let sessionObserver { DarwinNotify.stop(sessionObserver) }
        pollTimer?.invalidate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshFullAccessState()
        refreshChrome()
        consumeResultIfNeeded()
        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Prefer UIKit `hasFullAccess`, then App Group container + RW probe.
    private func refreshFullAccessState() {
        let allowed = hasFullAccess && FullAccessProbe.canOpenContainer
        needsFullAccessBanner = !allowed
        FullAccessProbe.reportFromKeyboard(hasFullAccess: allowed, defaults: relay.defaults)
    }

    private var canUseAppGroup: Bool {
        !needsFullAccessBanner
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshChrome()
            self?.consumeResultIfNeeded()
        }
    }

    private func refreshChrome() {
        let sessionOn = relay.isSessionActive
        let recording = relay.isRecording
        let level = relay.recordingLevel
        let hostStatus = relay.statusMessage
        keyboardView.setStatus(
            sessionOn: sessionOn,
            recording: recording,
            needsFullAccess: needsFullAccessBanner,
            level: level,
            hostStatus: hostStatus
        )
        if recording {
            keyboardView.setPreview("Listening…")
        } else if awaitingResult {
            keyboardView.setPreview(hostStatus.isEmpty ? "Transcribing…" : hostStatus)
        }
    }

    private func consumeResultIfNeeded() {
        guard canUseAppGroup else { return }
        if let err = relay.lastError {
            keyboardView.flash(err)
            keyboardView.setPreview(nil)
            awaitingResult = false
            relay.clearError()
            refreshChrome()
            return
        }
        guard let result = relay.consumeResult() else { return }
        if result.id == lastInsertedResultID { return }
        lastInsertedResultID = result.id
        textDocumentProxy.insertText(result.text)
        keyboardView.setPreview(result.text)
        keyboardView.flash("Inserted")
        awaitingResult = false
        refreshChrome()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.keyboardView.setPreview(nil)
        }
    }

    private func requestStartRecording() {
        guard canUseAppGroup else {
            keyboardView.flash("Enable Full Access + open AFK app")
            return
        }
        if !relay.isSessionActive {
            keyboardView.flash("Open AFK → Start session")
            DarwinNotify.post(AppGroupConstants.noteOpenHost)
            return
        }
        if relay.isRecording { return }
        _ = relay.postCommand(.start)
        keyboardView.flash("Listening…")
        awaitingResult = false
        refreshChrome()
    }

    private func requestStopRecording() {
        guard canUseAppGroup else { return }
        // Always post stop on release — host no-ops if not recording.
        _ = relay.postCommand(.stop)
        awaitingResult = true
        keyboardView.flash("Transcribing…")
        keyboardView.setPreview("Transcribing…")
        refreshChrome()
    }

    private func toggleRecording() {
        guard canUseAppGroup else {
            keyboardView.flash("Enable Full Access + open AFK app")
            return
        }
        if !relay.isSessionActive {
            keyboardView.flash("Open AFK → Start session")
            DarwinNotify.post(AppGroupConstants.noteOpenHost)
            return
        }
        if relay.isRecording {
            requestStopRecording()
        } else {
            requestStartRecording()
        }
    }
}

extension KeyboardViewController: KeyboardViewDelegate {
    func keyboardInsert(_ text: String) {
        // KeyboardView already applies shift casing for letter keys.
        textDocumentProxy.insertText(text)
        if shiftOn {
            shiftOn = false
            keyboardView.setShift(false)
        }
    }

    func keyboardDelete() {
        textDocumentProxy.deleteBackward()
    }

    func keyboardReturn() {
        textDocumentProxy.insertText("\n")
    }

    func keyboardSpace() {
        textDocumentProxy.insertText(" ")
    }

    func keyboardNextKeyboard() {
        advanceToNextInputMode()
    }

    func keyboardToggleShift() {
        shiftOn.toggle()
        keyboardView.setShift(shiftOn)
    }

    func keyboardMicHoldBegan() {
        requestStartRecording()
    }

    func keyboardMicHoldEnded() {
        requestStopRecording()
    }

    func keyboardMicTapped() {
        toggleRecording()
    }

    func keyboardSwitchToVoice() {
        keyboardView.setMode(.voice)
        refreshChrome()
    }

    func keyboardSwitchToTypingEN() {
        shiftOn = false
        keyboardView.setShift(false)
        keyboardView.setMode(.typingEN)
        refreshChrome()
    }

    func keyboardSwitchToTypingCN() {
        shiftOn = false
        keyboardView.setShift(false)
        keyboardView.setMode(.typingCN)
        refreshChrome()
    }
}
