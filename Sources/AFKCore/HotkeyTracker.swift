import Carbon.HIToolbox

/// Key-event state machine behind `KeyMonitor`, kept free of CGEvent so it can be unit-tested.
public struct HotkeyTracker: Sendable {
    public enum Input: Equatable, Sendable {
        case flagsChanged(fn: Bool)
        case keyDown(keyCode: UInt16, modifiers: HotkeyModifiers, isRepeat: Bool)
        case keyUp(keyCode: UInt16)
    }

    public enum Action: Equatable, Sendable {
        case began
        case ended
        case recorded(Hotkey)
        case recordingRejected
        case recordingCancelled
        /// Esc pressed while `interceptsEscape` is on (cancels a hands-free recording).
        case escapePressed
    }

    public struct Result: Equatable, Sendable {
        public var suppress: Bool
        public var action: Action?

        public static let pass = Result(suppress: false, action: nil)
        public static let swallow = Result(suppress: true, action: nil)
        static func suppress(_ action: Action) -> Result { Result(suppress: true, action: action) }
    }

    public var hotkey: Hotkey {
        didSet { if hotkey != oldValue { isActive = false } }
    }
    public var isEnabled = true
    /// When true, a bare Esc press is consumed and reported instead of reaching the app.
    public var interceptsEscape = false
    public private(set) var isActive = false
    public private(set) var isRecording = false

    /// Release events that belong to a press we already consumed.
    private var swallowKeyUp: UInt16?
    private var swallowFnRelease = false

    public init(hotkey: Hotkey = .defaultValue) {
        self.hotkey = hotkey
    }

    public mutating func startRecording() {
        isRecording = true
        isActive = false
    }

    public mutating func cancelRecording() {
        isRecording = false
    }

    public mutating func reset() {
        isActive = false
        swallowKeyUp = nil
        swallowFnRelease = false
    }

    public mutating func handle(_ input: Input) -> Result {
        switch input {
        case let .keyUp(code) where code == swallowKeyUp:
            swallowKeyUp = nil
            return .swallow
        case .flagsChanged(fn: false) where swallowFnRelease:
            swallowFnRelease = false
            return .swallow
        default:
            break
        }

        if isRecording { return record(input) }
        // Still deliver the release of a hold that started before disabling.
        guard isEnabled || isActive else { return .pass }

        if interceptsEscape, case let .keyDown(code, modifiers, _) = input,
           code == UInt16(kVK_Escape), modifiers.isEmpty {
            swallowKeyUp = code
            return .suppress(.escapePressed)
        }

        switch (hotkey, input) {
        case let (.fn, .flagsChanged(fn)):
            if fn && !isActive {
                isActive = true
                return .suppress(.began)
            }
            if !fn && isActive {
                isActive = false
                return .suppress(.ended)
            }
        case let (.combo(key, mods), .keyDown(code, modifiers, isRepeat)) where code == key:
            if isActive { return .swallow }
            if modifiers == mods && !isRepeat {
                isActive = true
                return .suppress(.began)
            }
        case let (.combo(key, _), .keyUp(code)) where code == key && isActive:
            isActive = false
            return .suppress(.ended)
        default:
            break
        }
        return .pass
    }

    private mutating func record(_ input: Input) -> Result {
        switch input {
        case .flagsChanged(fn: true):
            isRecording = false
            swallowFnRelease = true
            return .suppress(.recorded(.fn))
        case .flagsChanged:
            // Let modifier presses through so apps keep an accurate modifier state.
            return .pass
        case let .keyDown(code, modifiers, _):
            if code == UInt16(kVK_Escape) && modifiers.isEmpty {
                isRecording = false
                swallowKeyUp = code
                return .suppress(.recordingCancelled)
            }
            let candidate = Hotkey.combo(keyCode: code, modifiers: modifiers)
            guard candidate.isValid else { return .suppress(.recordingRejected) }
            isRecording = false
            swallowKeyUp = code
            return .suppress(.recorded(candidate))
        case .keyUp:
            return .swallow
        }
    }
}
