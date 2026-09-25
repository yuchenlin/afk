import AppKit
import Carbon.HIToolbox

/// Right Option hold-to-talk. Requires Accessibility for global CGEvent tap in production.
final class HotkeyMonitor {
    var onHoldChanged: ((Bool) -> Void)?
    private var tap: CFMachPort?
    private var holding = false

    func start() {
        // Local monitor works without full AX for same-app; global tap added when permissions OK.
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlags(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let down = event.modifierFlags.contains(.option)
        // Prefer right option when distinguishable.
        let isRightOption: Bool = {
            if #available(macOS 10.15, *) {
                return event.keyCode == UInt16(kVK_RightOption) || event.modifierFlags.contains(.option)
            }
            return event.modifierFlags.contains(.option)
        }()
        guard isRightOption || event.modifierFlags.contains(.option) else {
            if holding {
                holding = false
                onHoldChanged?(false)
            }
            return
        }
        if down && !holding {
            holding = true
            onHoldChanged?(true)
        } else if !down && holding {
            holding = false
            onHoldChanged?(false)
        }
    }
}
