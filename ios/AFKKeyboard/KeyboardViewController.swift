import UIKit

/// AFK Keyboard — Typeless-like voice-first UI; typing via ABC / 中文; host records via App Group.
/// Mic never opens `afk://` / foregrounds the host. Press-and-hold (or tap, tap) asks the
/// backgrounded host to unmute its armed mic for that one utterance; when the host cannot, an
/// in-keyboard CTA asks the user to open AFK once.
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
    private var lastPingFlushAt = Date.distantPast

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
        // Never leave the host mic open behind a hidden keyboard. Once stop is posted
        // (`awaitingResult`), leave it: cancel would overwrite it and drop the dictation.
        if canUseAppGroup, !awaitingResult, relay.isRecording || pendingStartCommandID != nil {
            _ = relay.postCommand(.cancel)
        }
        pendingStartCommandID = nil
        startWatchDeadline = nil
        awaitingResult = false
        keyboardView.resetMicGesture()
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
            self?.pingIfUtteranceOpen()
            self?.refreshChrome()
            self?.consumeResultIfNeeded()
            self?.watchPendingStart()
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    /// Host alive but its muted mic engine is gone — one foreground visit re-arms it.
    private func hostMicBlocked(health: SessionRelay.HostHealth) -> Bool {
        health != .down && relay.hostMicBlocked
    }

    /// Host closes the mic if these stop (keyboard killed mid-hold without sending stop).
    private func pingIfUtteranceOpen() {
        guard canUseAppGroup else { return }
        if pendingStartCommandID != nil || relay.isRecording || keyboardView.isMicLatched {
            ping()
        }
    }

    private func ping() {
        let flush = Date().timeIntervalSince(lastPingFlushAt) >= 0.5
        if flush { lastPingFlushAt = Date() }
        relay.touchKeyboardPing(flush: flush)
    }

    private func refreshChrome() {
        let sessionOn = relay.isSessionActive
        let recording = relay.isRecording
        let level = relay.recordingLevel
        let hostStatus = relay.statusMessage
        let health = relay.hostHealth()
        let micBlocked = sessionOn && hostMicBlocked(health: health)

        // Clear CTA once host is healthy again.
        if sessionOn, health == .ready, !micBlocked {
            activeCTA = nil
        } else if micBlocked, !recording {
            activeCTA = .recoverHost
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
        // Host dropped the utterance (interruption, cap, cancel) while tap-to-speak was latched.
        if keyboardView.isMicLatched, !recording, pendingStartCommandID == nil, !awaitingResult {
            keyboardView.resetMicGesture()
        }

        keyboardView.setStatus(
            sessionOn: sessionOn,
            recording: recording,
            needsFullAccess: needsFullAccessBanner,
            level: level,
            hostStatus: hostStatus,
            health: health,
            micBlocked: micBlocked,
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
            keyboardView.resetMicGesture()
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

    /// After posting start, confirm host actually opened the mic; never auto-open host.
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
        keyboardView.resetMicGesture()
        awaitingResult = false

        let health = relay.hostHealth()
        if health == .down {
            keyboardView.flash("AFK session stopped")
            keyboardView.setPreview("Open AFK once to resume")
            activeCTA = .sessionExpired
        } else {
            keyboardView.flash("AFK mic did not start")
            keyboardView.setPreview("Open AFK once, then come back")
            activeCTA = .recoverHost
        }
        refreshChrome()
    }

    private func requestStartRecording() {
        guard canUseAppGroup else {
            keyboardView.resetMicGesture()
            keyboardView.flash("Enable Full Access + open AFK app")
            return
        }
        if !relay.isSessionActive {
            keyboardView.resetMicGesture()
            activeCTA = .startSession
            keyboardView.flash("Open AFK once to start a session")
            keyboardView.setPreview("Start session in AFK")
            refreshChrome()
            return
        }
        let health = relay.hostHealth()
        if health == .down {
            keyboardView.resetMicGesture()
            activeCTA = .sessionExpired
            keyboardView.flash("Session paused — open AFK once")
            keyboardView.setPreview("Open AFK to resume")
            refreshChrome()
            return
        }
        // .ready or .degraded: App Group only — never openURL. A blocked host still gets the
        // command so the keyboard shows its exact error.
        if relay.isRecording || pendingStartCommandID != nil { return }
        lastPingFlushAt = .distantPast
        ping()
        let id = relay.postCommand(.start)
        pendingStartCommandID = id
        startWatchDeadline = Date().addingTimeInterval(2.0)
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

    func keyboardMicStart() {
        requestStartRecording()
    }

    func keyboardMicStop() {
        requestStopRecording()
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
