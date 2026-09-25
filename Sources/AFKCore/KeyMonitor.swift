import Cocoa

/// Hold-Fn push-to-talk via CGEventTap on `.flagsChanged` / `.maskSecondaryFn`.
/// Adapted from Scribe (MIT): https://github.com/xiangst0816/scribe
public final class KeyMonitor {
    public var onFnDown: (() -> Void)?
    public var onFnUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnPressed = false

    public init() {}

    /// Returns false if Accessibility permission is missing (tapCreate fails).
    @discardableResult
    public func start() -> Bool {
        stop()
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
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
        fnPressed = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let fnDown = event.flags.contains(.maskSecondaryFn)
        if fnDown && !fnPressed {
            fnPressed = true
            DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
            // Suppress Fn so emoji picker / globe shortcuts don't fire.
            return nil
        } else if !fnDown && fnPressed {
            fnPressed = false
            DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
            return nil
        }
        return Unmanaged.passRetained(event)
    }
}
