import UIKit
import OSLog

/// AFK Keyboard — Typeless-like voice-first UI; typing via ABC / 中文; host records via App Group.
/// Mic never opens `afk://` / foregrounds the host. Press-and-hold (or tap, tap) asks the
/// backgrounded host to unmute its armed mic for that one utterance; when the host cannot, an
/// in-keyboard CTA asks the user to open AFK once.
final class KeyboardViewController: UIInputViewController {
    private static let log = Logger(subsystem: "xyz.yuchenlin.afk.ios.keyboard", category: "insert")
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
    /// True between willAppear and willDisappear. Darwin can fire while disappearing;
    /// `insertText` then silently no-ops and a consume would permanently drop the result.
    private var keyboardVisible = false
    /// Set in viewDidAppear — textDocumentProxy is not reliably ready in willAppear.
    private var insertReady = false
    /// Last peeked result kept for the in-keyboard "Tap to insert" fallback.
    private var pendingPasteText: String?
    private var awaitingStartedAt: Date?

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
        keyboardVisible = true
        insertReady = false
        activeCTA = nil
        // Restore durable inserted-id so we do not re-insert after extension relaunch.
        if let stored = relay.defaults.string(forKey: AppGroupConstants.lastInsertedResultIDKey) {
            lastInsertedResultID = stored
        }
        refreshFullAccessState()
        keyboardView.reloadPolishFromDefaults()
        // If a result is already sitting in App Group (missed Darwin / we were backgrounded),
        // surface it in chrome immediately — actual insert waits for didAppear.
        if let pending = relay.peekResult() {
            pendingPasteText = pending.text
            awaitingResult = true
            awaitingStartedAt = awaitingStartedAt ?? Date()
        }
        refreshChrome()
        startPolling()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        keyboardVisible = true
        insertReady = true
        // Proxy is ready — drain any durable pending result now.
        consumeResultIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        keyboardVisible = false
        insertReady = false
        pollTimer?.invalidate()
        pollTimer = nil
        // Never leave the host mic open behind a hidden keyboard. Once stop is posted
        // (`awaitingResult`), leave it: cancel would overwrite it and drop the dictation.
        let hasPendingResult = relay.peekResult() != nil
        if canUseAppGroup, !awaitingResult, !hasPendingResult,
           relay.isRecording || pendingStartCommandID != nil {
            _ = relay.postCommand(.cancel)
        }
        pendingStartCommandID = nil
        startWatchDeadline = nil
        // CRITICAL: do NOT clear awaitingResult here. STT often finishes after the keyboard
        // is dismissed; clearing was a primary intermittent drop. Durable App Group +
        // viewDidAppear / next poll drain it.
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
            self?.watchAwaitingTimeout()
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
            // Host heartbeat gone — but a result may already be in App Group. Drain it first.
            if awaitingResult || relay.peekResult() != nil || pendingPasteText != nil {
                consumeResultIfNeeded()
                if relay.peekResult() == nil, pendingPasteText == nil {
                    awaitingResult = false
                    if keyboardVisible {
                        keyboardView.flash("AFK stopped — reopen to resume")
                    }
                }
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
            keyboardView.setPendingInsert(nil)
        } else if let pending = pendingPasteText, !pending.isEmpty {
            keyboardView.setPreview(pending)
            keyboardView.setPendingInsert(pending)
        } else if awaitingResult {
            keyboardView.setPreview(hostStatus.isEmpty ? "Transcribing…" : hostStatus)
            keyboardView.setPendingInsert(nil)
        } else {
            keyboardView.setPendingInsert(nil)
        }
    }

    private func consumeResultIfNeeded() {
        guard canUseAppGroup else { return }
        if let err = relay.lastError {
            keyboardView.flash(err)
            keyboardView.setPreview(nil)
            keyboardView.setPendingInsert(nil)
            awaitingResult = false
            pendingPasteText = nil
            pendingStartCommandID = nil
            startWatchDeadline = nil
            keyboardView.resetMicGesture()
            relay.clearError()
            refreshChrome()
            return
        }

        guard let result = relay.peekResult() else {
            return
        }
        Self.log.info("peek result id=\(result.id, privacy: .public) len=\(result.text.count) visible=\(self.keyboardVisible)")
        if result.id == lastInsertedResultID {
            relay.acknowledgeResult(id: result.id)
            return
        }

        // Stash for the "Tap to insert" fallback even if we cannot insert right now.
        pendingPasteText = result.text
        awaitingResult = true
        if awaitingStartedAt == nil { awaitingStartedAt = Date() }

        guard insertReady, keyboardVisible, isViewLoaded, view.window != nil else {
            keyboardView.setPreview(result.text)
            keyboardView.setPendingInsert(result.text)
            refreshChrome()
            return
        }

        insertPendingResult(source: "auto")
    }

    /// Insert the peeked / pending result into the host text field, then ack App Group.
    /// Only call while the keyboard is visible — otherwise leave App Group intact.
    @discardableResult
    private func insertPendingResult(source: String) -> Bool {
        let peeked = relay.peekResult()
        let text: String
        let id: String?
        if let peeked {
            if peeked.id == lastInsertedResultID {
                relay.acknowledgeResult(id: peeked.id)
                clearPendingInsertUI()
                return true
            }
            text = peeked.text
            id = peeked.id
        } else if let pending = pendingPasteText, !pending.isEmpty {
            text = pending
            id = nil
        } else if let clip = UIPasteboard.general.string, !clip.isEmpty, awaitingResult || source == "tap" {
            // Host always mirrors publishResult onto the pasteboard.
            text = clip
            id = nil
        } else {
            return false
        }

        guard insertReady, keyboardVisible, isViewLoaded, view.window != nil else {
            Self.log.info("defer insert (not ready) source=\(source, privacy: .public) len=\(text.count)")
            pendingPasteText = text
            keyboardView.setPreview(text)
            keyboardView.setPendingInsert(text)
            return false
        }

        Self.log.info("insertText source=\(source, privacy: .public) len=\(text.count) proxy=\(String(describing: type(of: self.textDocumentProxy)), privacy: .public)")
        // Trust insertText while we are the active keyboard. documentContext* is unreliable
        // (nil for secure fields, truncated otherwise) and must not gate ack — a failed
        // verification would leave the result in App Group and the 0.2s poll would
        // double-insert.
        textDocumentProxy.insertText(text)
        Self.log.info("insertText done; ack id=\(id ?? "nil", privacy: .public)")
        if let id {
            lastInsertedResultID = id
            relay.acknowledgeResult(id: id)
        } else if let peekedID = peeked?.id {
            lastInsertedResultID = peekedID
            relay.acknowledgeResult(id: peekedID)
        }
        // Keep a local copy briefly so the user can tap "Insert result" again if the
        // host field somehow ignored insertText (rare). Also ensure pasteboard has it.
        if UIPasteboard.general.string != text {
            UIPasteboard.general.string = text
        }
        clearPendingInsertUI()
        keyboardView.setPreview(text)
        keyboardView.flash("Inserted")
        // Keep a short-lived "Insert result" affordance in case the host field ignored
        // insertText; tap re-inserts from local/clipboard without needing App Group.
        if source == "auto" {
            pendingPasteText = text
            keyboardView.setPendingInsert(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self else { return }
                if self.pendingPasteText == text {
                    self.pendingPasteText = nil
                    self.keyboardView.setPendingInsert(nil)
                    self.keyboardView.setPreview(nil)
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.keyboardView.setPreview(nil)
            }
        }
        pendingStartCommandID = nil
        startWatchDeadline = nil
        refreshChrome()
        return true
    }

    private func clearPendingInsertUI() {
        awaitingResult = false
        awaitingStartedAt = nil
        pendingPasteText = nil
        keyboardView.setPendingInsert(nil)
    }

    /// Give up the "Transcribing…" chrome after a long wait, but NEVER delete a durable
    /// App Group result — peek/appear/tap can still insert it.
    private func watchAwaitingTimeout() {
        guard awaitingResult, let started = awaitingStartedAt else { return }
        guard Date().timeIntervalSince(started) > 90 else { return }
        if relay.peekResult() != nil {
            // Result is there — keep trying; just nudge the user.
            keyboardView.setPendingInsert(pendingPasteText ?? relay.peekResult()?.text)
            keyboardView.flash("Still have a result — tap Insert")
            awaitingStartedAt = Date() // re-arm nudge, don't clear
            return
        }
        awaitingResult = false
        awaitingStartedAt = nil
        keyboardView.flash("Transcription timed out — try again")
        keyboardView.setPreview(nil)
        refreshChrome()
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
        awaitingStartedAt = Date()
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

    func keyboardInsertPendingResultTapped() {
        _ = insertPendingResult(source: "tap")
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
