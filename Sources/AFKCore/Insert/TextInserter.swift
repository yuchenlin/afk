import Foundation

public protocol TextInserting: Sendable {
    func insert(_ text: String) throws
}

#if os(macOS)
import AppKit
import ApplicationServices

/// Accessibility insert with pasteboard fallback.
public struct MacTextInserter: TextInserting {
    public init() {}

    public func insert(_ text: String) throws {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        if err == .success, let element = focused {
            let ax = element as! AXUIElement
            var selected: CFTypeRef?
            if AXUIElementCopyAttributeValue(ax, kAXSelectedTextAttribute as CFString, &selected) == .success {
                let ok = AXUIElementSetAttributeValue(ax, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
                if ok == .success { return }
            }
        }
        // Fallback: clipboard + Cmd+V
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let src = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }
}
#else
public struct MacTextInserter: TextInserting {
    public init() {}
    public func insert(_ text: String) throws {
        throw AFKError.insertFailed("MacTextInserter is macOS-only")
    }
}
#endif
