import UIKit

/// AFK Keyboard — Typeless-like voice-first UI; typing via ABC / 中文; host records via App Group.
/// Mic never opens `afk://` / foregrounds the host. Session/keepalive must already be running;
/// otherwise an in-keyboard CTA asks the user to open AFK once.
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
    /// In-keyboard CTA only; mic path never auto-opens the host.
    private var activeCTA: HostCTA?
    private var lastCTAOpenAt: Date?

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
        activeCTA = nil
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
        let health = relay.hostHealth()

        // Clear CTA once host is healthy again.
        if sessionOn, health == .ready {
            activeCTA = nil
        } else if !sessionOn {
            activeCTA = canUseAppGroup ? .startSession : nil
        } else if health == .down {
            if activeCTA == nil || activeCTA == .startSession {
                activeCTA = .sessionExpired
            }
            if awaitingResult {
                awaitingResult = false
                keyboardView.flash("AFK stopped — reopen to resume")
            }
        }

        keyboardView.setStatus(
            sessionOn: sessionOn,
            recording: recording,
            needsFullAccess: needsFullAccessBanner,
            level: level,
            hostStatus: hostStatus,
            health: health,
            cta: needsFullAccessBanner ? nil : activeCTA
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

    /// After posting start, confirm host actually began recording; never auto-open host.
    private func watchPendingStart() {
        guard let deadline = startWatchDeadline, let cmdID = pendingStartCommandID else { return }
        if relay.isRecording {
            pendingStartCommandID = nil
            startWatchDeadline = nil
            activeCTA = nil
            return
        }
        // Host consumed our command but recording never flipped — still treat as progress.
        if relay.lastConsumedCommandID == cmdID, relay.hostHealth() != .down {
            if Date() < deadline { return }
        }
        guard Date() >= deadline else { return }

        pendingStartCommandID = nil
        startWatchDeadline = nil
        relay.clearPendingCommand()

        let health = relay.hostHealth()
        if health == .down {
            keyboardView.flash("AFK session stopped")
            keyboardView.setPreview("Open AFK once to resume")
            activeCTA = .sessionExpired
        } else {
            keyboardView.flash("Host did not start mic")
            keyboardView.setPreview("Open AFK to fix mic")
            activeCTA = .recoverHost
        }
        refreshChrome()
    }

    private func requestStartRecording() {
        guard canUseAppGroup else {
            keyboardView.flash("Enable Full Access + open AFK app")
            return
        }
        if !relay.isSessionActive {
            activeCTA = .startSession
            keyboardView.flash("Open AFK once to start a session")
            keyboardView.setPreview("Start session in AFK")
            refreshChrome()
            return
        }
        let health = relay.hostHealth()
        if health == .down {
            activeCTA = .sessionExpired
            keyboardView.flash("Session paused — open AFK once")
            keyboardView.setPreview("Open AFK to resume")
            refreshChrome()
            return
        }
        // .ready or .degraded: App Group only — never openURL.
        if relay.isRecording { return }
        let id = relay.postCommand(.start)
        pendingStartCommandID = id
        startWatchDeadline = Date().addingTimeInterval(1.2)
        if health == .degraded {
            keyboardView.flash("Waking session…")
        } else {
            keyboardView.flash("Listening…")
        }
        awaitingResult = false
        activeCTA = nil
        refreshChrome()
    }

    private func requestStopRecording() {
        guard canUseAppGroup else { return }
        // Nothing was ever started (mic held while the host was down) — do not
        // queue a stray stop or claim we are transcribing.
        guard relay.isRecording || pendingStartCommandID != nil else { return }
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
            activeCTA = .startSession
            keyboardView.flash("Open AFK once to start a session")
            keyboardView.setPreview("Start session in AFK")
            refreshChrome()
            return
        }
        if relay.isRecording {
            requestStopRecording()
        } else {
            requestStartRecording()
        }
    }

    /// Deliberate CTA tap only — the sole keyboard path that may open `afk://`.
    private func openHostFromCTA(_ cta: HostCTA) {
        guard canUseAppGroup else { return }
        if let last = lastCTAOpenAt, Date().timeIntervalSince(last) < 1.5 { return }
        lastCTAOpenAt = Date()
        guard let url = URL(string: "\(AppGroupConstants.urlScheme)://\(cta.urlPath)") else { return }
        keyboardView.flash("Opening AFK…")
        openURLFromExtension(url)
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

    func keyboardOpenHostTapped(_ cta: HostCTA) {
        openHostFromCTA(cta)
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
