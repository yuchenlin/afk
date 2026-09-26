import UIKit

protocol KeyboardViewDelegate: AnyObject {
    func keyboardInsert(_ text: String)
    func keyboardDelete()
    func keyboardReturn()
    func keyboardSpace()
    func keyboardNextKeyboard()
    func keyboardToggleShift()
    func keyboardMicTapped()
}

/// Minimal QWERTY + globe + mic — Guideline 4.4.1 requires real typing, not mic-only.
final class KeyboardView: UIView {
    weak var delegate: KeyboardViewDelegate?

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let stack = UIStackView()
    private var shiftButton: UIButton?
    private var micButton: UIButton?

    private let rows: [[String]] = [
        Array("qwertyuiop").map(String.init),
        Array("asdfghjkl").map(String.init),
        ["⇧"] + Array("zxcvbnm").map(String.init) + ["⌫"],
        ["🌐", "🎤", "space", "return"],
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemGray5

        titleLabel.text = "AFK Keyboard"
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.textColor = .secondaryLabel

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textAlignment = .center
        statusLabel.textColor = .orange
        statusLabel.numberOfLines = 2

        stack.axis = .vertical
        stack.spacing = 6
        stack.distribution = .fillEqually

        let header = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        header.axis = .vertical
        header.spacing = 2

        let root = UIStackView(arrangedSubviews: [header, stack])
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 4
            rowStack.distribution = .fillEqually
            for key in row {
                let button = makeKey(key)
                if key == "⇧" { shiftButton = button }
                if key == "🎤" { micButton = button }
                if key == "space" {
                    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
                }
                rowStack.addArrangedSubview(button)
                if key == "space" {
                    // Make space wider.
                    button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
                }
            }
            stack.addArrangedSubview(rowStack)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setShift(_ on: Bool) {
        shiftButton?.backgroundColor = on ? .systemBlue : .systemGray4
        shiftButton?.setTitleColor(on ? .white : .label, for: .normal)
    }

    func setStatus(sessionOn: Bool, recording: Bool, needsFullAccess: Bool) {
        if needsFullAccess {
            statusLabel.text = "Full Access off · typing OK · dictation needs app + Full Access"
            micButton?.backgroundColor = .systemGray3
        } else if recording {
            statusLabel.text = "Recording… tap 🎤 to stop"
            micButton?.backgroundColor = .systemRed
        } else if sessionOn {
            statusLabel.text = "Session on · tap 🎤 to dictate"
            micButton?.backgroundColor = .systemOrange
        } else {
            statusLabel.text = "No session · open AFK app → Start dictation session"
            micButton?.backgroundColor = .systemGray3
        }
    }

    func flash(_ message: String) {
        let previous = statusLabel.text
        statusLabel.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.statusLabel.text == message {
                self?.statusLabel.text = previous
            }
        }
    }

    private func makeKey(_ key: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .medium
        switch key {
        case "space": config.title = "space"
        case "return": config.title = "return"
        case "⌫": config.title = "⌫"
        case "⇧": config.title = "⇧"
        case "🌐": config.title = "🌐"
        case "🎤": config.title = "🎤"
        default: config.title = key
        }
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 4, bottom: 10, trailing: 4)
        let button = UIButton(configuration: config)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.addAction(UIAction { [weak self] _ in self?.handle(key) }, for: .touchUpInside)
        return button
    }

    private func handle(_ key: String) {
        switch key {
        case "⌫": delegate?.keyboardDelete()
        case "return": delegate?.keyboardReturn()
        case "space": delegate?.keyboardSpace()
        case "🌐": delegate?.keyboardNextKeyboard()
        case "⇧": delegate?.keyboardToggleShift()
        case "🎤": delegate?.keyboardMicTapped()
        default: delegate?.keyboardInsert(key)
        }
    }
}
