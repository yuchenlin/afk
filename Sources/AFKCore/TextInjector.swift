import AppKit
import Carbon

/// Clipboard + ⌘V insert with CJK IME swap dance.
/// Adapted from Scribe (MIT): https://github.com/xiangst0816/scribe
public final class TextInjector {
    public init() {}

    public func paste(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let savedText = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let needSwitch = !isASCIICapable(originalSource)
        if needSwitch, let asciiSource = findASCIICapableSource() {
            TISSelectInputSource(asciiSource)
            usleep(50_000)
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 0x09
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if needSwitch {
                TISSelectInputSource(originalSource)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            if let saved = savedText {
                pasteboard.setString(saved, forType: .string)
            }
        }
    }

    private func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return false
        }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    private func findASCIICapableSource() -> TISInputSource? {
        let criteria = [
            kTISPropertyInputSourceIsASCIICapable: true,
            kTISPropertyInputSourceIsEnabled: true,
        ] as CFDictionary
        guard let sourceList = TISCreateInputSourceList(criteria, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        for source in sourceList {
            if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                if id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US" {
                    return source
                }
            }
        }
        return sourceList.first
    }
}
