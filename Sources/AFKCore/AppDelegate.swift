import AppKit
import ApplicationServices
import AVFoundation

/// Menu-bar agent: hold the shortcut (⌘G by default) → Grok speech-to-text → paste at caret.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let keyMonitor = KeyMonitor(hotkey: Hotkey.load())
    private let injector = TextInjector()
    private let recorder = AudioRecorder()
    private let overlay = ListeningOverlay()
    private var lexicon = VocabularyStore.load()
    private let vocabularyWindow = VocabularyWindowController()
    private let history = HistoryStore()
    private let settingsWindow = SettingsWindowController()
    private lazy var historyWindow = HistoryWindowController(store: history) { [weak self] text in
        self?.injector.paste(text)
    }

    /// Holds shorter than this are treated as taps; combo taps are passed through to the app.
    private let minimumHold: TimeInterval = 0.15
    /// Hands-free mode: presses shorter than this start hands-free; longer ones act as push-to-talk.
    private let handsFreeTapLimit: TimeInterval = 0.5
    private let recordingTimeout: TimeInterval = 10

    private enum Capture {
        /// Push-to-talk: ends when the shortcut is released.
        case hold
        /// Ends on the next shortcut press, Esc (cancel), or auto-stop.
        case handsFree
        /// Menu "Test Transcription": fixed 3 s, shows text instead of pasting.
        case test
    }

    private var enabled = true
    private var settings = TalkSettings.load()
    private var capture: Capture?
    private var pressStartedAt: Date?
    /// The release after a press that ended hands-free recording must not start anything.
    private var ignoreNextRelease = false
    private var session: GrokSttSession?
    /// Why the current press can't record (missing key or microphone access).
    private var captureProblem: String?
    private var pauseDetector: PauseDetector?
    private var pauseTimer: Timer?
    /// Set while a `--self-test-*` step starts a recording; that recording shows its result
    /// instead of pasting. Real shortcut presses during a self-test still paste.
    private var selfTestStartingCapture = false
    private var captureIsSelfTest = false
    private var captureStartedAt: Date?
    /// After a permission error, polishing is skipped until this time so dictation stays fast.
    private var polishPausedUntil: Date?
    private var polishProblem: String?
    /// Missing or rejected API key / unknown model; shown at the top of the menu.
    private var apiProblem: String?
    /// Identifies the utterance awaiting a result; stale results and the watchdog check it.
    private var pendingResultID: UUID?
    private var copyLastItem: NSMenuItem!
    private var recordingTimeoutWork: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var hasPermission = false
    private var permissionItem: NSMenuItem!
    private var hintItem: NSMenuItem!
    private var enableItem: NSMenuItem!
    private var shortcutItem: NSMenuItem!
    private var microphoneItem: NSMenuItem!
    private var talkModeItem: NSMenuItem!
    private var vocabularyItem: NSMenuItem!
    private var historyItem: NSMenuItem!
    private var outputItem: NSMenuItem!
    private var apiItem: NSMenuItem!

    private var hotkey: Hotkey { keyMonitor.hotkey }
    private var isRecordingShortcut: Bool { recordingTimeoutWork != nil }

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        if ApiKeyStore.load() == nil { setApiProblem("No xAI API key — open Settings…") }
        promptAccessibilityIfNeeded()

        keyMonitor.onHotkeyDown = { [weak self] in self?.hotkeyDown() }
        keyMonitor.onHotkeyUp = { [weak self] in self?.hotkeyUp() }
        keyMonitor.onRecordingFinished = { [weak self] in self?.finishRecording($0) }
        keyMonitor.onRecordingRejected = { NSSound.beep() }
        keyMonitor.onEscape = { [weak self] in self?.cancelHandsFree() }
        vocabularyWindow.onSave = { [weak self] lexicon in self?.vocabularySaved(lexicon) }
        settingsWindow.onSave = { [weak self] in self?.settingsSaved() }
        installEditMenu()

        if !startListening() {
            overlay.showNotice("AFK needs Accessibility permission — see the menu bar", symbol: "exclamationmark.triangle.fill", autoHideAfter: 4)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        runSelfTestIfRequested()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                _ = self.startListening()
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        stopCapture(finish: false)
        keyMonitor.stop()
    }

    // MARK: - Listening

    /// Starts the key listener; while Accessibility is missing, retries every 2s so it
    /// starts as soon as the user grants permission.
    @discardableResult
    private func startListening() -> Bool {
        if keyMonitor.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            setPermission(true)
            return true
        }
        setPermission(false)
        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.keyMonitor.start() else { return }
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    self.setPermission(true)
                    self.overlay.showDone("AFK is ready — \(self.talkHint)")
                }
            }
        }
        return false
    }

    private func setPermission(_ granted: Bool) {
        hasPermission = granted
        permissionItem.isHidden = granted
        refreshShortcutMenu()
        refreshIdleTitle()
    }

    // MARK: - Talking

    private func hotkeyDown() {
        guard enabled, !isRecordingShortcut else { return }
        if capture == .handsFree {
            ignoreNextRelease = true
            stopCapture(finish: true)
            return
        }
        guard capture == nil, pendingResultID == nil else { return }

        let now = Date()
        pressStartedAt = now
        captureProblem = startCapture(.hold, at: now)
        if let problem = captureProblem {
            // Wait out the tap window so a quick shortcut tap doesn't flash a warning.
            DispatchQueue.main.asyncAfter(deadline: .now() + minimumHold) { [weak self] in
                guard let self, self.pressStartedAt == now else { return }
                self.overlay.showNotice(problem, symbol: "exclamationmark.triangle.fill", autoHideAfter: nil)
            }
        }
    }

    private func hotkeyUp() {
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        guard let pressed = pressStartedAt else { return }
        pressStartedAt = nil
        let held = Date().timeIntervalSince(pressed)

        if let problem = captureProblem {
            captureProblem = nil
            if held >= minimumHold {
                overlay.showNotice(problem, symbol: "exclamationmark.triangle.fill", autoHideAfter: 4)
            } else {
                overlay.hide()
                if settings.mode == .hold { keyMonitor.replay(hotkey) }
            }
            return
        }
        guard capture == .hold else { return }

        switch settings.mode {
        case .handsFree where held < handsFreeTapLimit:
            enterHandsFree()
        case .hold where held < minimumHold:
            stopCapture(finish: false)
            overlay.hide()
            keyMonitor.replay(hotkey)
        default:
            stopCapture(finish: true)
        }
    }

    private func enterHandsFree() {
        capture = .handsFree
        keyMonitor.interceptsEscape = true
        overlay.setHint("\(hotkey.displayName) to finish · esc to cancel")
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPause() }
        }
    }

    private func checkPause() {
        guard capture == .handsFree, let detector = pauseDetector,
              detector.shouldStop(at: Date(), autoStop: settings.autoStopAfterPause)
        else { return }
        stopCapture(finish: true)
    }

    private func cancelHandsFree() {
        guard capture == .handsFree else { return }
        stopCapture(finish: false)
        overlay.showNotice("Cancelled", symbol: "xmark.circle.fill", autoHideAfter: 1.2)
    }

    /// Starts mic capture and a streaming session; returns a user-facing reason if it can't.
    private func startCapture(_ kind: Capture, at start: Date) -> String? {
        guard let (apiKey, keySource) = ApiKeyStore.load() else {
            setApiProblem("No xAI API key — open Settings…")
            return "No xAI API key — open AFK → Settings… to add one"
        }
        sttLog.info("using API key from \(keySource.rawValue, privacy: .public)")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return "Allow microphone access, then try again"
        default:
            return "Microphone is off for AFK — System Settings → Privacy & Security → Microphone"
        }

        var sttConfig = GrokSttConfig(apiKey: apiKey, keyterms: lexicon.keyTermsForStt)
        sttConfig.model = ModelSettings.speechModel()
        let session = GrokSttSession(config: sttConfig)
        session.onPartial = { [weak self] text in
            guard let self else { return }
            self.overlay.updateTranscript(text)
            self.pauseDetector?.transcriptChanged(to: text, at: Date())
        }
        session.start()
        do {
            try recorder.start(
                device: selectedInputDevice(),
                onChunk: { session.append($0) },
                onLevel: { [weak self] level in
                    DispatchQueue.main.async { self?.overlay.updateLevel(level) }
                }
            )
        } catch {
            session.cancel()
            return "Microphone error: \(error.localizedDescription)"
        }
        self.session = session
        capture = kind
        captureIsSelfTest = selfTestStartingCapture
        captureStartedAt = start
        pauseDetector = PauseDetector(startedAt: start)
        setStatusIcon(active: true, text: nil)
        statusItem.button?.toolTip = "AFK recording…"
        overlay.showListening()
        return nil
    }

    /// Ends the current recording; `finish` transcribes and pastes (or shows, for the test).
    private func stopCapture(finish: Bool) {
        guard let kind = capture else { return }
        capture = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        pauseDetector = nil
        keyMonitor.interceptsEscape = false
        recorder.stop()
        refreshIdleTitle()
        let session = self.session
        self.session = nil
        guard finish, let session else {
            session?.cancel()
            return
        }
        let duration = captureStartedAt.map { Date().timeIntervalSince($0) }
        finishUtterance(
            session,
            paste: kind != .test && !captureIsSelfTest,
            record: !captureIsSelfTest,
            duration: duration
        )
    }

    private func finishUtterance(_ session: GrokSttSession, paste: Bool, record: Bool, duration: TimeInterval?) {
        overlay.showTranscribing()
        let id = UUID()
        pendingResultID = id
        session.finish { [weak self] result in
            guard let self, self.pendingResultID == id else { return }
            self.pendingResultID = nil
            self.deliver(result, paste: paste, record: record, duration: duration)
        }
        // The session falls back to batch after 4s and batch times out after 20s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.pendingResultID == id else { return }
            self.pendingResultID = nil
            session.cancel()
            self.overlay.showNotice("Transcription timed out — try again", symbol: "exclamationmark.triangle.fill", autoHideAfter: 5)
        }
    }

    /// The saved input device, or nil (system default) if none is saved or it's unplugged.
    private func selectedInputDevice() -> AudioInputDevice? {
        guard let uid = settings.inputDeviceUID else { return nil }
        if let device = AudioDevices.device(uid: uid) { return device }
        sttLog.info("saved microphone is unavailable; using the system default")
        return nil
    }

    private func deliver(_ result: Result<String, Error>, paste: Bool, record: Bool, duration: TimeInterval?) {
        if case .success = result { setApiProblem(nil) }
        switch result {
        case let .success(text) where !text.isEmpty:
            guard settings.outputStyle == .polished, Polisher.shouldPolish(text) else {
                finalize(text, raw: nil, paste: paste, record: record, duration: duration)
                return
            }
            if let until = polishPausedUntil, until > Date() {
                finalize(text, raw: nil, paste: paste, record: record, duration: duration,
                         fallbackReason: polishProblem ?? "polish unavailable")
                return
            }
            polish(text, paste: paste, record: record, duration: duration)
        case .success:
            overlay.showNotice("Didn't catch any speech — try again", symbol: "mic.slash.fill")
        case let .failure(error):
            if let problem = Self.apiProblem(for: error) {
                setApiProblem(problem + " — open Settings…")
                overlay.showNotice("\(problem) — open AFK → Settings… to test your key", symbol: "key.fill", autoHideAfter: 6)
            } else {
                overlay.showNotice("Transcription failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", autoHideAfter: 5)
            }
        }
    }

    /// Recognizes key and model errors from speech-to-text, which need the user to act in Settings.
    static func apiProblem(for error: Error) -> String? {
        guard case let GrokSttError.http(status, body) = error else { return nil }
        switch KeyCheck.from(status: status, body: Data(body.utf8), model: ModelSettings.speechModel(), seconds: 0) {
        case .invalidKey: return "API key rejected"
        case .noAccess: return "API key has no speech-to-text access"
        case .modelNotFound: return "Speech model not found"
        default: return nil
        }
    }

    private func setApiProblem(_ problem: String?) {
        guard apiProblem != problem else { return }
        apiProblem = problem
        refreshApiMenu()
    }

    private func refreshApiMenu() {
        apiItem.title = "⚠️ " + (apiProblem ?? "")
        apiItem.isHidden = apiProblem == nil
    }

    @objc private func openSettings(_ sender: NSMenuItem?) {
        settingsWindow.show()
    }

    private func settingsSaved() {
        setApiProblem(nil)
        polishProblem = nil
        polishPausedUntil = nil
        refreshOutputMenu()
        overlay.showDone("Settings saved — used from the next recording")
    }

    private func polish(_ raw: String, paste: Bool, record: Bool, duration: TimeInterval?) {
        guard let (apiKey, _) = ApiKeyStore.load() else {
            finalize(raw, raw: nil, paste: paste, record: record, duration: duration)
            return
        }
        overlay.showPolishing()
        let id = UUID()
        pendingResultID = id
        let config = PolishConfig(apiKey: apiKey, model: ModelSettings.polishModel(), vocabulary: lexicon.keyTermsForStt)
        Polisher.polish(raw, config: config) { [weak self] result in
            guard let self, self.pendingResultID == id else { return }
            self.pendingResultID = nil
            switch result {
            case let .success(polished):
                self.polishProblem = nil
                self.polishPausedUntil = nil
                self.finalize(polished, raw: polished == raw ? nil : raw, paste: paste, record: record, duration: duration)
            case let .failure(error):
                let reason = error.localizedDescription
                if case PolishError.permissionDenied = error {
                    self.polishProblem = "polish unavailable: \(reason) (see Settings → Test Key)"
                    self.polishPausedUntil = Date().addingTimeInterval(300)
                    self.refreshOutputMenu()
                }
                self.finalize(raw, raw: nil, paste: paste, record: record, duration: duration,
                              fallbackReason: "polish failed: \(reason)")
            }
        }
    }

    /// Records the transcript in history and pastes (or shows) it. `fallbackReason` explains
    /// why the original was used although polishing was requested.
    private func finalize(
        _ text: String,
        raw: String?,
        paste: Bool,
        record: Bool,
        duration: TimeInterval?,
        fallbackReason: String? = nil
    ) {
        if record {
            history.add(TranscriptEntry(
                text: text,
                rawText: raw,
                duration: duration,
                appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                pasted: paste
            ))
            refreshHistoryMenu()
        }
        if paste { injector.paste(text) }
        if let fallbackReason {
            let what = paste ? "Pasted original" : "Heard (original): \(text)"
            overlay.showNotice("\(what) — \(fallbackReason)", symbol: "exclamationmark.triangle.fill", autoHideAfter: 4)
        } else if paste {
            overlay.showDone(raw == nil ? "Pasted" : "Pasted (polished)")
        } else {
            overlay.showDone("Heard: \(text)")
        }
    }

    // MARK: - Diagnostics

    /// `open AFK.app --args <option>` drives the same code paths as the shortcut, without
    /// pasting, so the talk flow can be checked end to end without sending key presses:
    /// `--self-test` (menu Test Transcription), `--self-test-handsfree` (tap, 3 s, tap),
    /// `--self-test-cancel` (tap, 1.5 s, Esc), `--self-test-hold` (hold 2 s, release),
    /// `--self-test-autostop` (tap once; relies on auto-stop), `--self-test-polish [text]`.
    private func runSelfTestIfRequested() {
        let args = CommandLine.arguments
        let after: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
        }
        if let i = args.firstIndex(of: "--self-test-polish") {
            let sample = args.indices.contains(i + 1) ? args[i + 1]
                : "I feel the, the ... the product harness could be on the ... cursor codebase, you know."
            after(1) { [weak self] in
                self?.deliver(.success(sample), paste: false, record: false, duration: nil)
            }
            return
        }
        if args.contains("--open-settings") {
            after(0.5) { [weak self] in self?.openSettings(nil) }
            return
        }
        if args.contains("--open-history") {
            after(0.5) { [weak self] in self?.openHistory(nil) }
            return
        }
        if args.contains("--open-vocabulary") {
            after(0.5) { [weak self] in self?.openVocabulary(nil) }
            return
        }
        if args.contains("--self-test") {
            after(1) { [weak self] in self?.testTranscription(nil) }
            return
        }
        let flows: [String: [(TimeInterval, (AppDelegate) -> Void)]] = [
            "--self-test-handsfree": [(1, { $0.hotkeyDown() }), (1.1, { $0.hotkeyUp() }),
                                      (4.1, { $0.hotkeyDown() }), (4.2, { $0.hotkeyUp() })],
            "--self-test-cancel": [(1, { $0.hotkeyDown() }), (1.1, { $0.hotkeyUp() }),
                                   (2.6, { $0.cancelHandsFree() })],
            "--self-test-hold": [(1, { $0.hotkeyDown() }), (3, { $0.hotkeyUp() })],
            "--self-test-autostop": [(1, { $0.hotkeyDown() }), (1.1, { $0.hotkeyUp() })],
        ]
        guard let (name, steps) = flows.first(where: { args.contains($0.key) }) else { return }
        sttLog.info("self-test \(name, privacy: .public), mode=\(self.settings.mode.rawValue, privacy: .public)")
        for (delay, step) in steps {
            after(delay) { [weak self] in
                guard let self else { return }
                self.selfTestStartingCapture = true
                step(self)
                self.selfTestStartingCapture = false
                sttLog.info("self-test step at \(delay, privacy: .public)s: capture=\(String(describing: self.capture), privacy: .public)")
            }
        }
    }

    // MARK: - Shortcut

    private func applyHotkey(_ newValue: Hotkey) {
        guard newValue.isValid else { return }
        stopCapture(finish: false)
        pressStartedAt = nil
        keyMonitor.hotkey = newValue
        newValue.save()
        refreshShortcutMenu()
        refreshIdleTitle()
    }

    private func beginRecording() {
        guard startListening() else {
            showAccessibilityAlert()
            return
        }
        stopCapture(finish: false)
        pressStartedAt = nil
        keyMonitor.startRecording()
        setStatusIcon(active: false, text: "Press shortcut…")
        statusItem.button?.toolTip = "Press the new AFK shortcut, or Esc to cancel"
        overlay.showNotice("Press the new shortcut (Esc to cancel)", symbol: "keyboard", autoHideAfter: nil)

        let timeout = DispatchWorkItem { [weak self] in
            self?.keyMonitor.cancelRecording()
            self?.finishRecording(nil)
        }
        recordingTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + recordingTimeout, execute: timeout)
    }

    private func finishRecording(_ recorded: Hotkey?) {
        recordingTimeoutWork?.cancel()
        recordingTimeoutWork = nil
        if let recorded {
            applyHotkey(recorded)
            overlay.showDone("Shortcut set to \(recorded.displayName)")
        } else {
            refreshIdleTitle()
            overlay.hide()
        }
    }

    // MARK: - Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false
        permissionItem = NSMenuItem(
            title: "⚠️ Grant Accessibility Permission…",
            action: #selector(openAccessibilitySettings(_:)),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)

        apiItem = NSMenuItem(title: "", action: #selector(openSettings(_:)), keyEquivalent: "")
        apiItem.target = self
        apiItem.isHidden = true
        menu.addItem(apiItem)

        hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        enableItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enableItem.state = .on
        enableItem.target = self
        menu.addItem(enableItem)

        shortcutItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        shortcutItem.submenu = NSMenu()
        menu.addItem(shortcutItem)

        talkModeItem = NSMenuItem(title: "Talk Mode", action: nil, keyEquivalent: "")
        menu.addItem(talkModeItem)

        outputItem = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
        menu.addItem(outputItem)

        vocabularyItem = NSMenuItem(title: "Vocabulary…", action: #selector(openVocabulary(_:)), keyEquivalent: "")
        vocabularyItem.target = self
        menu.addItem(vocabularyItem)

        microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        // Rebuilt on every open so newly plugged-in devices appear.
        micMenu.delegate = self
        microphoneItem.submenu = micMenu
        menu.addItem(microphoneItem)

        menu.addItem(NSMenuItem.separator())

        let testItem = NSMenuItem(
            title: "Test Transcription (3 s)",
            action: #selector(testTranscription(_:)),
            keyEquivalent: ""
        )
        testItem.target = self
        menu.addItem(testItem)

        historyItem = NSMenuItem(title: "History…", action: #selector(openHistory(_:)), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        copyLastItem = NSMenuItem(
            title: "Copy Last Transcript",
            action: #selector(copyLastTranscript(_:)),
            keyEquivalent: ""
        )
        copyLastItem.target = self
        menu.addItem(copyLastItem)

        let test = NSMenuItem(
            title: "Paste test string",
            action: #selector(pasteTest(_:)),
            keyEquivalent: ""
        )
        test.target = self
        menu.addItem(test)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(
            title: "Quit AFK",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
        refreshTalkModeMenu()
        refreshMicrophoneMenu()
        refreshVocabularyMenu()
        refreshOutputMenu()
        refreshHistoryMenu()
        refreshShortcutMenu()
        refreshIdleTitle()
    }

    /// Menu bar shows the AFK face; `active` (filled) while recording, plus optional text.
    private func setStatusIcon(active: Bool, text: String?) {
        guard let button = statusItem.button else { return }
        button.image = LogoMark.menuBarImage(active: active)
        button.imagePosition = text == nil ? .imageOnly : .imageLeft
        button.title = text.map { " " + $0 } ?? ""
    }

    private var talkHint: String {
        switch settings.mode {
        case .hold: return "hold \(hotkey.displayName) to talk"
        case .handsFree: return "tap \(hotkey.displayName) to start and stop (or hold to talk)"
        }
    }

    private func refreshIdleTitle() {
        guard !isRecordingShortcut else { return }
        if hasPermission {
            setStatusIcon(active: false, text: nil)
            statusItem.button?.toolTip = "AFK — \(talkHint)"
        } else {
            setStatusIcon(active: false, text: "⚠︎")
            statusItem.button?.toolTip = "AFK needs Accessibility permission"
        }
    }

    private func refreshShortcutMenu() {
        hintItem.title = hasPermission
            ? talkHint.prefix(1).uppercased() + talkHint.dropFirst()
            : "Not listening — Accessibility permission needed"
        shortcutItem.title = "Shortcut: \(hotkey.displayName)"

        let submenu = NSMenu()
        var presets: [(Hotkey, String)] = [
            (.defaultValue, "\(Hotkey.defaultValue.displayName) (Default)"),
            (.fn, "Fn"),
        ]
        if !presets.contains(where: { $0.0 == hotkey }) {
            presets.append((hotkey, "Custom: \(hotkey.displayName)"))
        }
        for (preset, title) in presets {
            let item = NSMenuItem(title: title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = try? JSONEncoder().encode(preset)
            item.state = preset == hotkey ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(NSMenuItem.separator())
        let record = NSMenuItem(
            title: "Record New Shortcut…",
            action: #selector(recordShortcut(_:)),
            keyEquivalent: ""
        )
        record.target = self
        submenu.addItem(record)
        shortcutItem.submenu = submenu
    }

    private func refreshTalkModeMenu() {
        let title: String
        switch settings.mode {
        case .hold: title = "Hold to Talk"
        case .handsFree: title = settings.autoStopAfterPause ? "Hands-Free, Auto-Stop" : "Hands-Free"
        }
        talkModeItem.title = "Talk Mode: \(title)"

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let options: [(TalkMode, String)] = [
            (.hold, "Hold to Talk"),
            (.handsFree, "Hands-Free — tap \(hotkey.displayName) to start/stop, Esc cancels"),
        ]
        for (mode, label) in options {
            let item = NSMenuItem(title: label, action: #selector(selectTalkMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = settings.mode == mode ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(NSMenuItem.separator())
        let autoStop = NSMenuItem(
            title: "Auto-Stop After a Pause (Hands-Free)",
            action: #selector(toggleAutoStop(_:)),
            keyEquivalent: ""
        )
        autoStop.target = self
        autoStop.state = settings.autoStopAfterPause ? .on : .off
        autoStop.isEnabled = settings.mode == .handsFree
        submenu.addItem(autoStop)
        talkModeItem.submenu = submenu
    }

    private func refreshMicrophoneMenu() {
        let devices = AudioDevices.inputDevices()
        let defaultName = AudioDevices.defaultInputDevice()?.name
        let saved = settings.inputDeviceUID
        let current = saved.flatMap { uid in devices.first { $0.uid == uid } }
        microphoneItem.title = "Microphone: \(current?.name ?? defaultName.map { "Default (\($0))" } ?? "Default")"

        guard let submenu = microphoneItem.submenu else { return }
        submenu.removeAllItems()
        let defaultItem = NSMenuItem(
            title: "System Default" + (defaultName.map { " (\($0))" } ?? ""),
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.state = saved == nil ? .on : .off
        submenu.addItem(defaultItem)
        submenu.addItem(NSMenuItem.separator())
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == saved ? .on : .off
            submenu.addItem(item)
        }
        if let saved, current == nil {
            let missing = NSMenuItem(title: "Saved microphone disconnected — using default", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            missing.toolTip = saved
            submenu.addItem(NSMenuItem.separator())
            submenu.addItem(missing)
        }
    }

    private func refreshOutputMenu() {
        outputItem.title = "Output: " + (settings.outputStyle == .polished ? "Polished" : "Original")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let options: [(OutputStyle, String)] = [
            (.original, "Original — exactly what was heard"),
            (.polished, "Polished — remove fillers, repeats and false starts"),
        ]
        for (style, label) in options {
            let item = NSMenuItem(title: label, action: #selector(selectOutputStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = settings.outputStyle == style ? .on : .off
            submenu.addItem(item)
        }
        if let polishProblem, settings.outputStyle == .polished {
            submenu.addItem(.separator())
            let info = NSMenuItem(title: "⚠️ " + polishProblem.prefix(1).uppercased() + polishProblem.dropFirst(), action: nil, keyEquivalent: "")
            info.isEnabled = false
            submenu.addItem(info)
        }
        outputItem.submenu = submenu
    }

    @objc private func selectOutputStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = OutputStyle(rawValue: raw) else { return }
        settings.outputStyle = style
        settings.save()
        // Re-check access right away if the user switches polishing back on.
        polishPausedUntil = nil
        refreshOutputMenu()
    }

    private func refreshHistoryMenu() {
        historyItem.title = "History… (\(history.entries.count))"
        copyLastItem.isEnabled = !history.entries.isEmpty
    }

    @objc private func openHistory(_ sender: NSMenuItem?) {
        historyWindow.show()
    }

    private func refreshVocabularyMenu() {
        vocabularyItem.title = "Vocabulary… (\(lexicon.keyTermsForStt.count) terms)"
    }

    @objc private func openVocabulary(_ sender: NSMenuItem?) {
        vocabularyWindow.show()
    }

    private func vocabularySaved(_ newLexicon: LexiconStore) {
        lexicon = newLexicon
        refreshVocabularyMenu()
        sttLog.info("vocabulary saved: \(newLexicon.keyTermsForStt.count, privacy: .public) key terms")
        overlay.showDone("Vocabulary saved: \(newLexicon.keyTermsForStt.count) terms, used from the next recording")
    }

    /// Accessory apps have no visible menu bar, but text fields still need the standard
    /// Edit key equivalents (⌘X/⌘C/⌘V/⌘A/⌘Z), which are routed through the main menu.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func selectTalkMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = TalkMode(rawValue: raw) else { return }
        if capture == .handsFree { stopCapture(finish: false) }
        settings.mode = mode
        settings.save()
        refreshTalkModeMenu()
        refreshShortcutMenu()
        refreshIdleTitle()
        overlay.showDone("Talk mode: \(mode == .hold ? "hold \(hotkey.displayName) to talk" : "tap \(hotkey.displayName) to start and stop")")
    }

    @objc private func toggleAutoStop(_ sender: NSMenuItem) {
        settings.autoStopAfterPause.toggle()
        settings.save()
        refreshTalkModeMenu()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        settings.inputDeviceUID = sender.representedObject as? String
        settings.save()
        refreshMicrophoneMenu()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? Data,
              let preset = try? JSONDecoder().decode(Hotkey.self, from: data)
        else { return }
        applyHotkey(preset)
    }

    @objc private func recordShortcut(_ sender: NSMenuItem) {
        beginRecording()
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.state = enabled ? .on : .off
        keyMonitor.isEnabled = enabled
        if enabled {
            if !startListening() {
                showAccessibilityAlert()
            }
        } else {
            stopCapture(finish: false)
            pressStartedAt = nil
            overlay.hide()
            refreshIdleTitle()
        }
    }

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        promptAccessibilityIfNeeded()
        openAccessibilityPane()
    }

    /// Records 3 s and shows the transcript in the pill without pasting.
    @objc private func testTranscription(_ sender: NSMenuItem?) {
        guard capture == nil, pendingResultID == nil else { return }
        if let problem = startCapture(.test, at: Date()) {
            overlay.showNotice(problem, symbol: "exclamationmark.triangle.fill", autoHideAfter: 4)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.capture == .test else { return }
            self.stopCapture(finish: true)
        }
    }

    @objc private func copyLastTranscript(_ sender: NSMenuItem) {
        guard let text = history.entries.first?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func pasteTest(_ sender: NSMenuItem) {
        injector.paste("AFK test paste — cursor insert OK.")
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem.menu || menu === microphoneItem.submenu { refreshMicrophoneMenu() }
        if menu === statusItem.menu { refreshHistoryMenu() }
    }

    // MARK: - Permissions

    private func promptAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility required"
        alert.informativeText = """
        AFK needs Accessibility to watch its shortcut (\(hotkey.displayName)) and paste into other apps.

        System Settings → Privacy & Security → Accessibility → enable AFK, and AFK starts listening within a few seconds.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        // Accessory apps aren't frontmost, so the alert would open behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilityPane()
        }
    }

    private func openAccessibilityPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
