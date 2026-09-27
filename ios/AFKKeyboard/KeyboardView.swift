import UIKit

protocol KeyboardViewDelegate: AnyObject {
    func keyboardInsert(_ text: String)
    func keyboardDelete()
    func keyboardReturn()
    func keyboardSpace()
    func keyboardNextKeyboard()
    func keyboardToggleShift()
    /// Mic touch-down (hold-to-talk or first tap of tap-to-speak): open the host mic now.
    func keyboardMicStart()
    /// Hold released, or second tap in tap-to-speak: close the mic and transcribe.
    func keyboardMicStop()
    func keyboardSwitchToVoice()
    func keyboardSwitchToTypingEN()
    func keyboardSwitchToTypingCN()
    /// Deliberate CTA — only path that may open the AFK host from the keyboard.
    func keyboardOpenHostTapped(_ cta: HostCTA)
}

enum KeyboardSurfaceMode {
    case voice
    case typingEN
    case typingCN
}

/// Typeless-like keyboard: voice/transcription is primary; EN / 中文 typing only after switch.
/// Guideline 4.4.1: typing layouts + globe + Full Access messaging remain available.
final class KeyboardView: UIView {
    weak var delegate: KeyboardViewDelegate?

    private(set) var mode: KeyboardSurfaceMode = .voice

    private let root = UIStackView()
    private let statusLabel = UILabel()
    private let previewLabel = UILabel()
    private let contentHost = UIView()

    // Voice chrome (Typeless-like: brand | modes · hold/tap hint · pill mic · bottom chrome)
    private let voiceStack = UIStackView()
    private let headerBar = UIStackView()
    private let brandLabel = UILabel()
    private let modeBar = UIStackView()
    private var modeVoiceBtn: UIButton!
    private var modeENBtn: UIButton!
    private var modeCNBtn: UIButton!
    private let micButton = UIButton(type: .custom)
    private let waveform = WaveformView()
    private let holdHint = UILabel()
    private let ctaButton = UIButton(type: .system)
    /// CTA the button currently represents; the tap carries it so the button is never dead.
    private var shownCTA: HostCTA?
    private let voiceBottom = UIView()
    private let voiceReturn = UIButton(type: .system)
    private let voiceAIBtn = UIButton(type: .system)
    private let voiceGlobe = UIButton(type: .system)
    private let voiceBackspace = UIButton(type: .system)
    private let voiceAt = UIButton(type: .system)

    // Typing chrome
    private let typingStack = UIStackView()
    private let candidateScroll = UIScrollView()
    private let candidateRow = UIStackView()
    private let keysStack = UIStackView()
    private var shiftButton: UIButton?
    private var shiftOn = false

    // Shared bottom bar pieces rebuilt per mode
    private var pinyinBuffer = ""
    private var candidates: [String] = []

    /// Mic gesture: touch-down starts at once (no pre-roll exists, so waiting would clip the
    /// first syllable). Release after `holdThreshold` = hold-to-talk → stop. A shorter touch
    /// latches tap-to-speak; the next touch-down stops.
    private enum MicGesture { case idle, pressing(since: Date), latched }
    private var micGesture: MicGesture = .idle
    private let holdThreshold: TimeInterval = 0.4

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        buildChrome()
        applyMode(.voice, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setMode(_ mode: KeyboardSurfaceMode) {
        guard mode != self.mode else { return }
        applyMode(mode, animated: true)
    }

    func setShift(_ on: Bool) {
        shiftOn = on
        shiftButton?.backgroundColor = on ? .systemBlue : .systemGray4
        shiftButton?.setTitleColor(on ? .white : .label, for: .normal)
    }

    func setStatus(
        sessionOn: Bool,
        recording: Bool,
        needsFullAccess: Bool,
        level: Float,
        hostStatus: String,
        health: SessionRelay.HostHealth = .ready,
        micBlocked: Bool = false,
        cta: HostCTA? = nil
    ) {
        waveform.level = recording ? level : 0
        waveform.isHidden = !recording || mode != .voice
        let sendHint = isMicLatched ? "Listening… tap to send" : "Listening… release to send"

        if needsFullAccess {
            statusLabel.text = "Full Access off · typing OK · dictation needs AFK app + Full Access"
            statusLabel.textColor = .systemOrange
            styleMic(ready: false, recording: false)
            holdHint.text = "Enable Full Access"
            applyCTA(nil)
        } else if recording {
            statusLabel.text = hostStatus.isEmpty ? sendHint : hostStatus
            statusLabel.textColor = .systemRed
            styleMic(ready: true, recording: true)
            holdHint.text = sendHint
            applyCTA(nil)
        } else if sessionOn, health == .down {
            statusLabel.text = "Session paused · open AFK once to resume"
            statusLabel.textColor = .systemOrange
            styleMic(ready: false, recording: false)
            holdHint.text = "Open AFK to resume"
            applyCTA(cta ?? .sessionExpired)
        } else if sessionOn, micBlocked {
            statusLabel.text = "iOS turned the AFK mic off (call, Siri or audio change)"
            statusLabel.textColor = .systemOrange
            styleMic(ready: false, recording: false)
            holdHint.text = "Open AFK once to turn it back on"
            applyCTA(cta ?? .recoverHost)
        } else if sessionOn, health == .degraded {
            let base = hostStatus.isEmpty ? "Session on · waking…" : hostStatus
            statusLabel.text = base
            statusLabel.textColor = UIColor(white: 0.65, alpha: 1)
            styleMic(ready: true, recording: false)
            holdHint.text = isMicLatched ? sendHint : "Hold to talk · or tap"
            applyCTA(cta)
        } else if sessionOn {
            let base = hostStatus.isEmpty ? "Session on · mic muted until you hold" : hostStatus
            statusLabel.text = base
            statusLabel.textColor = UIColor(white: 0.65, alpha: 1)
            styleMic(ready: true, recording: false)
            holdHint.text = isMicLatched ? sendHint : "Hold to talk · or tap"
            applyCTA(cta)
        } else {
            statusLabel.text = "No session · open AFK → Start dictation session"
            statusLabel.textColor = .systemOrange
            styleMic(ready: false, recording: false)
            holdHint.text = "Open AFK once"
            applyCTA(cta ?? .startSession)
        }
    }

    func setPreview(_ text: String?) {
        if let text, !text.isEmpty {
            previewLabel.text = text
            previewLabel.isHidden = false
        } else {
            previewLabel.text = nil
            previewLabel.isHidden = true
        }
    }

    func flash(_ message: String) {
        let previous = statusLabel.text
        let previousColor = statusLabel.textColor
        statusLabel.text = message
        statusLabel.textColor = .label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.statusLabel.text == message else { return }
            self.statusLabel.text = previous
            self.statusLabel.textColor = previousColor
        }
    }

    // MARK: - Build

    private func buildChrome() {
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.textColor = .secondaryLabel

        previewLabel.font = .systemFont(ofSize: 15, weight: .medium)
        previewLabel.textAlignment = .center
        previewLabel.numberOfLines = 2
        previewLabel.textColor = .white
        previewLabel.isHidden = true

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.setContentHuggingPriority(.defaultLow, for: .vertical)

        root.addArrangedSubview(statusLabel)
        root.addArrangedSubview(previewLabel)
        root.addArrangedSubview(contentHost)
        contentHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        buildVoiceSurface()
        buildTypingSurface()
    }

    private func buildVoiceSurface() {
        voiceStack.axis = .vertical
        voiceStack.alignment = .fill
        voiceStack.spacing = 14
        voiceStack.translatesAutoresizingMaskIntoConstraints = false

        // Top: AFK brand · waveform | EN | 拼
        headerBar.axis = .horizontal
        headerBar.alignment = .center
        headerBar.distribution = .equalSpacing
        headerBar.translatesAutoresizingMaskIntoConstraints = false

        brandLabel.text = "AFK"
        brandLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        brandLabel.textColor = .white

        modeBar.axis = .horizontal
        modeBar.spacing = 4
        modeBar.alignment = .center
        modeVoiceBtn = makeModeChip(systemName: "waveform", selected: true)
        modeENBtn = makeModeChip(title: "EN", selected: false)
        modeCNBtn = makeModeChip(title: "拼", selected: false)
        modeVoiceBtn.addAction(UIAction { [weak self] _ in self?.delegate?.keyboardSwitchToVoice() }, for: .touchUpInside)
        modeENBtn.addAction(UIAction { [weak self] _ in self?.delegate?.keyboardSwitchToTypingEN() }, for: .touchUpInside)
        modeCNBtn.addAction(UIAction { [weak self] _ in self?.delegate?.keyboardSwitchToTypingCN() }, for: .touchUpInside)
        modeBar.addArrangedSubview(modeVoiceBtn)
        modeBar.addArrangedSubview(modeENBtn)
        modeBar.addArrangedSubview(modeCNBtn)
        headerBar.addArrangedSubview(brandLabel)
        headerBar.addArrangedSubview(modeBar)

        holdHint.font = .systemFont(ofSize: 15, weight: .medium)
        holdHint.textColor = UIColor(white: 0.7, alpha: 1)
        holdHint.textAlignment = .center
        holdHint.text = "Hold to talk · or tap"

        // Large white pill mic (Typeless)
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.layer.cornerRadius = 28
        micButton.clipsToBounds = true
        let micConfig = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: micConfig), for: .normal)
        micButton.tintColor = .black
        micButton.backgroundColor = .white
        micButton.accessibilityLabel = "Hold to talk, or tap to start and tap again to send"
        micButton.addTarget(self, action: #selector(micTouchDown), for: .touchDown)
        micButton.addTarget(self, action: #selector(micTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.isHidden = true

        // Bottom chrome: AI · return · backspace / globe · @
        voiceBottom.translatesAutoresizingMaskIntoConstraints = false
        styleRoundChrome(voiceAIBtn, systemName: "pencil.and.outline")
        styleRoundChrome(voiceGlobe, systemName: "globe")
        styleRoundChrome(voiceBackspace, systemName: "delete.left.fill")
        styleRoundChrome(voiceAt, title: "@")
        voiceReturn.setTitle("return", for: .normal)
        voiceReturn.setTitleColor(.white, for: .normal)
        voiceReturn.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        voiceReturn.backgroundColor = UIColor(white: 0.22, alpha: 1)
        voiceReturn.layer.cornerRadius = 22
        voiceReturn.translatesAutoresizingMaskIntoConstraints = false
        voiceAIBtn.addAction(UIAction { [weak self] _ in self?.flash("AI polish runs in the AFK host") }, for: .touchUpInside)
        voiceGlobe.addAction(UIAction { [weak self] _ in self?.delegate?.keyboardNextKeyboard() }, for: .touchUpInside)
        voiceBackspace.addAction(UIAction { [weak self] _ in self?.delegate?.keyboardDelete() }, for: .touchUpInside)
        voiceAt.addAction(UIAction { [weak self] _ in self?.delegate?.keyboardInsert("@") }, for: .touchUpInside)
        voiceReturn.addAction(UIAction { [weak self] _ in self?.delegate?.keyboardReturn() }, for: .touchUpInside)

        [voiceAIBtn, voiceGlobe, voiceBackspace, voiceAt, voiceReturn].forEach { voiceBottom.addSubview($0) }
        NSLayoutConstraint.activate([
            voiceAIBtn.leadingAnchor.constraint(equalTo: voiceBottom.leadingAnchor, constant: 8),
            voiceAIBtn.topAnchor.constraint(equalTo: voiceBottom.topAnchor),
            voiceAIBtn.widthAnchor.constraint(equalToConstant: 44),
            voiceAIBtn.heightAnchor.constraint(equalToConstant: 44),
            voiceGlobe.leadingAnchor.constraint(equalTo: voiceBottom.leadingAnchor, constant: 8),
            voiceGlobe.bottomAnchor.constraint(equalTo: voiceBottom.bottomAnchor),
            voiceGlobe.widthAnchor.constraint(equalToConstant: 44),
            voiceGlobe.heightAnchor.constraint(equalToConstant: 44),
            voiceBackspace.trailingAnchor.constraint(equalTo: voiceBottom.trailingAnchor, constant: -8),
            voiceBackspace.topAnchor.constraint(equalTo: voiceBottom.topAnchor),
            voiceBackspace.widthAnchor.constraint(equalToConstant: 44),
            voiceBackspace.heightAnchor.constraint(equalToConstant: 44),
            voiceAt.trailingAnchor.constraint(equalTo: voiceBottom.trailingAnchor, constant: -8),
            voiceAt.bottomAnchor.constraint(equalTo: voiceBottom.bottomAnchor),
            voiceAt.widthAnchor.constraint(equalToConstant: 44),
            voiceAt.heightAnchor.constraint(equalToConstant: 44),
            voiceReturn.centerXAnchor.constraint(equalTo: voiceBottom.centerXAnchor),
            voiceReturn.centerYAnchor.constraint(equalTo: voiceBottom.centerYAnchor),
            voiceReturn.widthAnchor.constraint(equalToConstant: 160),
            voiceReturn.heightAnchor.constraint(equalToConstant: 44),
            voiceBottom.heightAnchor.constraint(equalToConstant: 100),
        ])

        ctaButton.translatesAutoresizingMaskIntoConstraints = false
        ctaButton.backgroundColor = UIColor(white: 0.22, alpha: 1)
        ctaButton.layer.cornerRadius = 18
        ctaButton.tintColor = .white
        ctaButton.setTitleColor(.white, for: .normal)
        ctaButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        ctaButton.titleLabel?.adjustsFontSizeToFitWidth = true
        ctaButton.titleLabel?.minimumScaleFactor = 0.75
        ctaButton.titleLabel?.lineBreakMode = .byTruncatingTail
        ctaButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        let ctaCfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        ctaButton.setImage(UIImage(systemName: "arrow.up.forward.app", withConfiguration: ctaCfg), for: .normal)
        ctaButton.accessibilityLabel = "Open AFK to start a dictation session"
        ctaButton.accessibilityHint = "Opens the AFK app once; afterwards dictation stays in this app."
        ctaButton.isHidden = true
        ctaButton.addAction(UIAction { [weak self] _ in
            guard let self, let cta = self.shownCTA else { return }
            self.delegate?.keyboardOpenHostTapped(cta)
        }, for: .touchUpInside)

        let micWrap = UIStackView(arrangedSubviews: [ctaButton, holdHint, micButton, waveform])
        micWrap.axis = .vertical
        micWrap.alignment = .center
        micWrap.spacing = 12

        voiceStack.addArrangedSubview(headerBar)
        voiceStack.addArrangedSubview(micWrap)
        voiceStack.addArrangedSubview(voiceBottom)

        NSLayoutConstraint.activate([
            ctaButton.heightAnchor.constraint(equalToConstant: 36),
            ctaButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            ctaButton.widthAnchor.constraint(lessThanOrEqualTo: voiceStack.widthAnchor, multiplier: 0.96),
            micButton.widthAnchor.constraint(equalTo: voiceStack.widthAnchor, multiplier: 0.72),
            micButton.heightAnchor.constraint(equalToConstant: 56),
            waveform.widthAnchor.constraint(equalTo: voiceStack.widthAnchor, multiplier: 0.55),
            waveform.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func applyCTA(_ cta: HostCTA?) {
        shownCTA = cta
        guard let cta else {
            ctaButton.isHidden = true
            return
        }
        ctaButton.setTitle("  " + cta.title, for: .normal)
        ctaButton.accessibilityLabel = cta.title
        ctaButton.isHidden = mode != .voice
    }

    private func makeModeChip(title: String? = nil, systemName: String? = nil, selected: Bool) -> UIButton {
        let btn = UIButton(type: .system)
        if let systemName {
            let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            btn.setImage(UIImage(systemName: systemName, withConfiguration: cfg), for: .normal)
        } else {
            btn.setTitle(title, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        }
        btn.tintColor = selected ? .white : UIColor(white: 0.65, alpha: 1)
        btn.setTitleColor(selected ? .white : UIColor(white: 0.65, alpha: 1), for: .normal)
        btn.backgroundColor = selected ? UIColor(white: 0.28, alpha: 1) : .clear
        btn.layer.cornerRadius = 14
        btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        btn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return btn
    }

    private func styleRoundChrome(_ btn: UIButton, systemName: String? = nil, title: String? = nil) {
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.backgroundColor = UIColor(white: 0.22, alpha: 1)
        btn.layer.cornerRadius = 22
        btn.tintColor = .white
        btn.setTitleColor(.white, for: .normal)
        if let systemName {
            let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            btn.setImage(UIImage(systemName: systemName, withConfiguration: cfg), for: .normal)
        } else if let title {
            btn.setTitle(title, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        }
    }

    private func refreshModeChips() {
        let voice = mode == .voice
        let en = mode == .typingEN
        let cn = mode == .typingCN
        guard modeVoiceBtn != nil else { return }
        for (btn, on) in [(modeVoiceBtn!, voice), (modeENBtn!, en), (modeCNBtn!, cn)] {
            btn.backgroundColor = on ? UIColor(white: 0.28, alpha: 1) : .clear
            btn.tintColor = on ? .white : UIColor(white: 0.65, alpha: 1)
            btn.setTitleColor(on ? .white : UIColor(white: 0.65, alpha: 1), for: .normal)
        }
    }

    private func buildTypingSurface() {
        typingStack.axis = .vertical
        typingStack.spacing = 6
        typingStack.translatesAutoresizingMaskIntoConstraints = false

        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false
        candidateRow.axis = .horizontal
        candidateRow.spacing = 6
        candidateRow.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.addSubview(candidateRow)
        NSLayoutConstraint.activate([
            candidateRow.leadingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.leadingAnchor, constant: 4),
            candidateRow.trailingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.trailingAnchor, constant: -4),
            candidateRow.topAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.topAnchor),
            candidateRow.bottomAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.bottomAnchor),
            candidateRow.heightAnchor.constraint(equalTo: candidateScroll.frameLayoutGuide.heightAnchor),
        ])
        candidateScroll.heightAnchor.constraint(equalToConstant: 36).isActive = true
        candidateScroll.isHidden = true

        keysStack.axis = .vertical
        keysStack.spacing = 6
        keysStack.distribution = .fillEqually

        typingStack.addArrangedSubview(candidateScroll)
        typingStack.addArrangedSubview(keysStack)
    }

    private func applyMode(_ mode: KeyboardSurfaceMode, animated: Bool) {
        self.mode = mode
        voiceStack.removeFromSuperview()
        typingStack.removeFromSuperview()
        contentHost.subviews.forEach { $0.removeFromSuperview() }

        let surface: UIView
        switch mode {
        case .voice:
            surface = voiceStack
            clearPinyin()
        case .typingEN, .typingCN:
            rebuildTypingKeys()
            surface = typingStack
            candidateScroll.isHidden = (mode != .typingCN)
        }

        surface.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            surface.topAnchor.constraint(equalTo: contentHost.topAnchor),
            surface.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])

        refreshModeChips()
        if animated {
            surface.alpha = 0
            UIView.animate(withDuration: 0.18) { surface.alpha = 1 }
        }
    }

    private func rebuildTypingKeys() {
        keysStack.arrangedSubviews.forEach {
            keysStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        shiftButton = nil

        let rows: [[String]]
        if mode == .typingCN {
            rows = [
                Array("qwertyuiop").map(String.init),
                Array("asdfghjkl").map(String.init),
                ["⇧"] + Array("zxcvbnm").map(String.init) + ["⌫"],
                ["🌐", "🎤", "ABC", "空格", "确认"],
            ]
        } else {
            rows = [
                Array("qwertyuiop").map(String.init),
                Array("asdfghjkl").map(String.init),
                ["⇧"] + Array("zxcvbnm").map(String.init) + ["⌫"],
                ["🌐", "🎤", "中文", "space", "return"],
            ]
        }

        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 4
            rowStack.distribution = .fillEqually
            for key in row {
                let button = makeKey(key)
                if key == "⇧" { shiftButton = button }
                if key == "space" || key == "空格" {
                    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
                    button.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
                }
                rowStack.addArrangedSubview(button)
            }
            keysStack.addArrangedSubview(rowStack)
        }
        refreshCandidates()
    }

    private func makeChromeKey(_ key: String) -> UIButton {
        makeKey(key)
    }

    private func makeKey(_ key: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .medium
        switch key {
        case "space": config.title = "space"
        case "空格": config.title = "空格"
        case "return": config.title = "return"
        case "确认": config.title = "确认"
        case "⌫": config.title = "⌫"
        case "⇧": config.title = "⇧"
        case "🌐": config.title = "🌐"
        case "🎤": config.title = "🎤"
        case "ABC": config.title = "ABC"
        case "中文": config.title = "中文"
        default: config.title = key
        }
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 2, bottom: 10, trailing: 2)
        let button = UIButton(configuration: config)
        button.titleLabel?.font = .systemFont(ofSize: key.count > 1 ? 13 : 16, weight: .medium)
        button.addAction(UIAction { [weak self] _ in self?.handle(key) }, for: .touchUpInside)
        return button
    }

    private func styleMic(ready: Bool, recording: Bool) {
        if recording {
            micButton.backgroundColor = .systemRed
            micButton.tintColor = .white
            micButton.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
        } else if ready {
            micButton.backgroundColor = .white
            micButton.tintColor = .black
            micButton.transform = .identity
        } else {
            micButton.backgroundColor = UIColor(white: 0.35, alpha: 1)
            micButton.tintColor = UIColor(white: 0.75, alpha: 1)
            micButton.transform = .identity
        }
    }

    // MARK: - Mic gestures

    @objc private func micTouchDown() {
        switch micGesture {
        case .latched:
            micGesture = .idle
            delegate?.keyboardMicStop()
        case .idle, .pressing:
            micGesture = .pressing(since: Date())
            delegate?.keyboardMicStart()
        }
    }

    @objc private func micTouchUp() {
        guard case let .pressing(since) = micGesture else { return }
        if Date().timeIntervalSince(since) >= holdThreshold {
            micGesture = .idle
            delegate?.keyboardMicStop()
        } else {
            micGesture = .latched
            holdHint.text = "Listening… tap to send"
        }
    }

    /// Controller: the utterance ended outside the gesture (start refused, result/error in,
    /// keyboard hidden). Next touch-down starts a new one.
    func resetMicGesture() {
        micGesture = .idle
    }

    /// True while a tap-to-speak utterance is waiting for its second tap.
    var isMicLatched: Bool {
        if case .latched = micGesture { return true }
        return false
    }

    // MARK: - Key handling

    private func handle(_ key: String) {
        switch key {
        case "⌫":
            if mode == .typingCN, !pinyinBuffer.isEmpty {
                pinyinBuffer.removeLast()
                refreshCandidates()
            } else {
                delegate?.keyboardDelete()
            }
        case "return", "确认":
            if mode == .typingCN, !pinyinBuffer.isEmpty {
                commitPinyinRaw()
            } else {
                delegate?.keyboardReturn()
            }
        case "space", "空格":
            if mode == .typingCN {
                if let first = candidates.first {
                    selectCandidate(first)
                } else if !pinyinBuffer.isEmpty {
                    commitPinyinRaw()
                } else {
                    delegate?.keyboardSpace()
                }
            } else {
                delegate?.keyboardSpace()
            }
        case "🌐":
            delegate?.keyboardNextKeyboard()
        case "⇧":
            delegate?.keyboardToggleShift()
        case "🎤":
            delegate?.keyboardSwitchToVoice()
        case "ABC":
            delegate?.keyboardSwitchToTypingEN()
        case "中文":
            delegate?.keyboardSwitchToTypingCN()
        default:
            if mode == .typingCN, key.count == 1, key.first?.isLetter == true {
                pinyinBuffer.append(contentsOf: key.lowercased())
                refreshCandidates()
            } else {
                let out = shiftOn ? key.uppercased() : key
                delegate?.keyboardInsert(out)
                if shiftOn {
                    shiftOn = false
                    setShift(false)
                }
            }
        }
    }

    private func refreshCandidates() {
        candidates = mode == .typingCN ? PinyinIME.candidates(for: pinyinBuffer) : []
        candidateRow.arrangedSubviews.forEach {
            candidateRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if !pinyinBuffer.isEmpty {
            let buf = UILabel()
            buf.text = " \(pinyinBuffer) "
            buf.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            buf.textColor = .secondaryLabel
            candidateRow.addArrangedSubview(buf)
        }
        for word in candidates {
            var config = UIButton.Configuration.plain()
            config.title = word
            config.baseForegroundColor = .label
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            let button = UIButton(configuration: config)
            button.backgroundColor = .systemBackground
            button.layer.cornerRadius = 8
            button.addAction(UIAction { [weak self] _ in self?.selectCandidate(word) }, for: .touchUpInside)
            candidateRow.addArrangedSubview(button)
        }
        candidateScroll.isHidden = mode != .typingCN
    }

    private func selectCandidate(_ word: String) {
        delegate?.keyboardInsert(word)
        clearPinyin()
    }

    private func commitPinyinRaw() {
        guard !pinyinBuffer.isEmpty else { return }
        delegate?.keyboardInsert(pinyinBuffer)
        clearPinyin()
    }

    private func clearPinyin() {
        pinyinBuffer = ""
        candidates = []
        refreshCandidates()
    }
}

// MARK: - Waveform

private final class WaveformView: UIView {
    var level: Float = 0 {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let bars = 16
        let spacing: CGFloat = 3
        let totalSpacing = spacing * CGFloat(bars - 1)
        let barWidth = max(2, (rect.width - totalSpacing) / CGFloat(bars))
        let midY = rect.midY
        let color = UIColor.systemOrange.cgColor
        ctx.setFillColor(color)
        for i in 0..<bars {
            let phase = abs(sin(CGFloat(i) * 0.7 + CGFloat(level) * 8))
            let h = max(4, CGFloat(level) * rect.height * (0.35 + 0.65 * phase))
            let x = CGFloat(i) * (barWidth + spacing)
            let y = midY - h / 2
            let path = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: barWidth, height: h), cornerRadius: 2)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
        }
    }
}
