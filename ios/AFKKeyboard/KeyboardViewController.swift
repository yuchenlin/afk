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
    private var pendingStartCommandID: String?
    private var startWatchDeadline: Date?
    private var didOfferHostWake = false

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
        didOfferHostWake = false
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refreshChrome()
            self?.consumeResultIfNeeded()
            self?.watchPendingStart()
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    private func refreshChrome() {
        let sessionOn = relay.isSessionActive
        let recording = relay.isRecording
        let level = relay.recordingLevel
        let hostStatus = relay.statusMessage
        let hostAlive = relay.isHostHeartbeatFresh()
        keyboardView.setStatus(
            sessionOn: sessionOn,
            recording: recording,
            needsFullAccess: needsFullAccessBanner,
            level: level,
            hostStatus: hostStatus,
            hostAlive: hostAlive
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
            pendingStartCommandID = nil
            startWatchDeadline = nil
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
        pendingStartCommandID = nil
        startWatchDeadline = nil
        refreshChrome()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.keyboardView.setPreview(nil)
        }
    }

    /// After posting start, confirm host actually began recording; otherwise surface failure + wake host.
    private func watchPendingStart() {
        guard let deadline = startWatchDeadline, let cmdID = pendingStartCommandID else { return }
        if relay.isRecording {
            pendingStartCommandID = nil
            startWatchDeadline = nil
            didOfferHostWake = false
            return
        }
        // Host consumed our command but recording never flipped — still treat as progress.
        if relay.lastConsumedCommandID == cmdID, relay.isHostHeartbeatFresh() {
            // Give capture a moment after consume.
            if Date() < deadline { return }
        }
        guard Date() >= deadline else { return }

        pendingStartCommandID = nil
        startWatchDeadline = nil

        let hostAlive = relay.isHostHeartbeatFresh()
        if !hostAlive {
            keyboardView.flash("Host suspended — opening AFK…")
            keyboardView.setPreview("Host not running · open AFK")
            wakeHost(path: AppGroupConstants.urlHostWake)
        } else {
            keyboardView.flash("Host did not start mic")
            keyboardView.setPreview("Host alive but mic did not start")
            wakeHost(path: AppGroupConstants.urlHostRecord)
        }
        refreshChrome()
    }

    private func requestStartRecording() {
        guard canUseAppGroup else {
            keyboardView.flash("Enable Full Access + open AFK app")
            return
        }
        if !relay.isSessionActive {
            keyboardView.flash("No session — opening AFK…")
            keyboardView.setPreview("Start session in AFK")
            wakeHost(path: AppGroupConstants.urlHostSession)
            DarwinNotify.post(AppGroupConstants.noteOpenHost)
            return
        }
        if !relay.isHostHeartbeatFresh() {
            keyboardView.flash("Host asleep — opening AFK…")
            keyboardView.setPreview("Session flag on, host not alive")
            wakeHost(path: AppGroupConstants.urlHostWake)
            // Still post the command so a freshly woken host can drain it.
        }
        if relay.isRecording { return }
        let id = relay.postCommand(.start)
        pendingStartCommandID = id
        startWatchDeadline = Date().addingTimeInterval(1.2)
        keyboardView.flash("Listening…")
        awaitingResult = false
        refreshChrome()
    }

    private func requestStopRecording() {
        guard canUseAppGroup else { return }
        // Always post stop on release — host no-ops if not recording.
        _ = relay.postCommand(.stop)
        awaitingResult = true
        pendingStartCommandID = nil
        startWatchDeadline = nil
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
            keyboardView.flash("No session — opening AFK…")
            keyboardView.setPreview("Start session in AFK")
            wakeHost(path: AppGroupConstants.urlHostSession)
            DarwinNotify.post(AppGroupConstants.noteOpenHost)
            return
        }
        if relay.isRecording {
            requestStopRecording()
        } else {
            requestStartRecording()
        }
    }

    /// Open the host via URL scheme (Full Access). Wakes a suspended AFK so keepalive can resume.
    private func wakeHost(path: String) {
        guard canUseAppGroup else { return }
        if didOfferHostWake { return }
        didOfferHostWake = true
        guard let url = URL(string: "\(AppGroupConstants.urlScheme)://\(path)") else { return }
        openURLFromExtension(url)
        // Allow another wake attempt after a few seconds if user retries mic.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.didOfferHostWake = false
        }
    }

    private func openURLFromExtension(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let application = r as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }
        // Fallbacks used by some keyboard / iOS combinations with Full Access.
        let sharedSel = NSSelectorFromString("sharedApplication")
        let openSel = NSSelectorFromString("openURL:")
        if let appClass = NSClassFromString("UIApplication") as? NSObject.Type,
           appClass.responds(to: sharedSel),
           let app = appClass.perform(sharedSel)?.takeUnretainedValue() as? NSObject,
           app.responds(to: openSel) {
            _ = app.perform(openSel, with: url)
            return
        }
        extensionContext?.open(url, completionHandler: nil)
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
