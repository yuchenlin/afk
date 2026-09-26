import UIKit

/// AFK Keyboard (WIP): basic QWERTY + mic that relays to the host via App Group / Darwin.
final class KeyboardViewController: UIInputViewController {
    private let relay = SessionRelay.shared
    private var keyboardView: KeyboardView!
    private var resultObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?
    private var shiftOn = false
    private var needsFullAccessBanner = false

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
        needsFullAccessBanner = !canUseAppGroup
        refreshChrome()
        consumeResultIfNeeded()
    }

    /// App Group suite only resolves when Full Access is on (and entitlement matches).
    private var canUseAppGroup: Bool {
        UserDefaults(suiteName: AppGroupConstants.suiteName) != nil
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
            if let err = relay.lastError {
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
            // Keyboards cannot reliably open the host URL; user starts session in app.
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
        // Optimistic UI; host updates App Group.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshChrome()
        }
    }
}
