import Cocoa

/// Push-to-talk shortcut listener (Fn or a key combo such as ⌘G) via a CGEventTap.
/// Fn handling adapted from Scribe (MIT): https://github.com/xiangst0816/scribe
/// The tap runs on the main run loop; use this class from the main thread only.
public final class KeyMonitor {
    public var onHotkeyDown: (() -> Void)?
    public var onHotkeyUp: (() -> Void)?
    /// Called with the new shortcut, or nil if recording was cancelled with Esc.
    public var onRecordingFinished: ((Hotkey?) -> Void)?
    public var onRecordingRejected: (() -> Void)?
    public var onEscape: (() -> Void)?

    public var hotkey: Hotkey {
        get { tracker.hotkey }
        set { tracker.hotkey = newValue }
    }

    public var isEnabled: Bool {
        get { tracker.isEnabled }
        set { tracker.isEnabled = newValue }
    }

    /// Consume bare Esc presses and report them via `onEscape` (while hands-free recording).
    public var interceptsEscape: Bool {
        get { tracker.interceptsEscape }
        set { tracker.interceptsEscape = newValue }
    }

    public var isRunning: Bool { eventTap != nil }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tracker: HotkeyTracker

    /// Tags events AFK posts itself so the tap lets them through.
    private static let syntheticMarker: Int64 = 0x41_46_4B

    public init(hotkey: Hotkey = .defaultValue) {
        tracker = HotkeyTracker(hotkey: hotkey)
    }

    /// Returns false if Accessibility permission is missing (tapCreate fails).
    /// No-op when the tap is already running.
    @discardableResult
    public func start() -> Bool {
        if isRunning { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        tracker.reset()
    }

    /// The next valid key press (or Fn) becomes the shortcut; Esc cancels.
    public func startRecording() {
        tracker.startRecording()
    }

    public func cancelRecording() {
        tracker.cancelRecording()
    }

    /// Re-sends a combo shortcut to the focused app, so a quick tap of ⌘G still means Find Next.
    public func replay(_ hotkey: Hotkey) {
        guard case let .combo(keyCode, modifiers) = hotkey else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
                continue
            }
            event.flags = modifiers.cgFlags
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let input: HotkeyTracker.Input
        switch type {
        case .flagsChanged:
            input = .flagsChanged(fn: event.flags.contains(.maskSecondaryFn))
        case .keyDown:
            input = .keyDown(
                keyCode: keyCode,
                modifiers: HotkeyModifiers(event.flags),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .keyUp:
            input = .keyUp(keyCode: keyCode)
        default:
            return Unmanaged.passUnretained(event)
        }

        let result = tracker.handle(input)
        if let action = result.action {
            DispatchQueue.main.async { [weak self] in self?.dispatch(action) }
        }
        return result.suppress ? nil : Unmanaged.passUnretained(event)
    }

    private func dispatch(_ action: HotkeyTracker.Action) {
        switch action {
        case .began: onHotkeyDown?()
        case .ended: onHotkeyUp?()
        case let .recorded(hotkey): onRecordingFinished?(hotkey)
        case .recordingCancelled: onRecordingFinished?(nil)
        case .recordingRejected: onRecordingRejected?()
        case .escapePressed: onEscape?()
        }
    }
}
