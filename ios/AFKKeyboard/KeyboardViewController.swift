import UIKit

/// AFK Keyboard: basic QWERTY + mic that relays to the host via App Group / Darwin.
final class KeyboardViewController: UIInputViewController {
    private var keyboardView: KeyboardView!
    private let relay = SessionRelay.shared
    private var shiftOn = false
    private var needsFullAccessBanner = false
    private var resultObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?

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
            kv.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshFullAccessState()
        refreshChrome()
        consumeResultIfNeeded()
    }

    /// Prefer UIKit `hasFullAccess`, then App Group container + RW probe.
    /// (Never use `UserDefaults(suiteName:) != nil` — that is always true.)
    private func refreshFullAccessState() {
        let allowed = hasFullAccess && FullAccessProbe.canOpenContainer
        needsFullAccessBanner = !allowed
        FullAccessProbe.reportFromKeyboard(hasFullAccess: allowed, defaults: relay.defaults)
    }

    private var canUseAppGroup: Bool {
        // needsFullAccessBanner already encodes hasFullAccess + App Group container.
        !needsFullAccessBanner
    }

    private func refreshChrome() {
        let sessionOn = relay.isSessionActive
        let recording = relay.isRecording
        keyboardView.setStatus(
            sessionOn: sessionOn,
            recording: recording,
            needsFullAccess: needsFullAccessBanner
        )
    }

    private func consumeResultIfNeeded() {
        guard canUseAppGroup, let result = relay.consumeResult() else {
            if canUseAppGroup, let err = relay.lastError {
                keyboardView.flash(err)
                relay.clearError()
            }
            return
        }
        textDocumentProxy.insertText(result.text)
        keyboardView.flash("Inserted")
        refreshChrome()
    }
}

extension KeyboardViewController: KeyboardViewDelegate {
    func keyboardInsert(_ text: String) {
        let out = shiftOn ? text.uppercased() : text
        textDocumentProxy.insertText(out)
        if shiftOn { shiftOn = false; keyboardView.setShift(false) }
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

    func keyboardMicTapped() {
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
            DarwinNotify.post(AppGroupConstants.noteStopRecording)
            keyboardView.flash("Stopping…")
        } else {
            DarwinNotify.post(AppGroupConstants.noteStartRecording)
            keyboardView.flash("Listening…")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshChrome()
        }
    }
}
