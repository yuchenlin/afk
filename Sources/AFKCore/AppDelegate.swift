import AppKit
import ApplicationServices

/// Minimal menu-bar agent: hold Fn → mock transcript → paste at caret.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let keyMonitor = KeyMonitor()
    private let injector = TextInjector()
    private let mockStt = MockSttClient()

    private var enabled = true
    private var holdStartedAt: Date?
    private var enableItem: NSMenuItem!

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        promptAccessibilityIfNeeded()

        keyMonitor.onFnDown = { [weak self] in self?.fnDown() }
        keyMonitor.onFnUp = { [weak self] in self?.fnUp() }

        if !keyMonitor.start() {
            showAccessibilityAlert()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                _ = self.keyMonitor.start()
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        keyMonitor.stop()
    }

    // MARK: - Fn

    private func fnDown() {
        guard enabled, holdStartedAt == nil else { return }
        holdStartedAt = Date()
        statusItem.button?.title = "●"
        statusItem.button?.toolTip = "AFK recording…"
    }

    private func fnUp() {
        guard let start = holdStartedAt else { return }
        holdStartedAt = nil
        statusItem.button?.title = "AFK"
        statusItem.button?.toolTip = "AFK — hold Fn to talk"

        let duration = Date().timeIntervalSince(start)
        // Ignore accidental taps
        guard duration >= 0.15 else { return }

        let text = mockStt.transcribe(holdDuration: duration)
        injector.paste(text)
    }

    // MARK: - Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "AFK"
            button.toolTip = "AFK — hold Fn to talk"
        }

        let menu = NSMenu()
        enableItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enableItem.state = .on
        enableItem.target = self
        menu.addItem(enableItem)

        menu.addItem(NSMenuItem.separator())

        let test = NSMenuItem(
            title: "Paste test string",
            action: #selector(pasteTest(_:)),
            keyEquivalent: ""
        )
        test.target = self
        menu.addItem(test)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit AFK",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.state = enabled ? .on : .off
        if enabled {
            if !keyMonitor.start() {
                showAccessibilityAlert()
            }
        } else {
            keyMonitor.stop()
            holdStartedAt = nil
            statusItem.button?.title = "AFK"
        }
    }

    @objc private func pasteTest(_ sender: NSMenuItem) {
        injector.paste("AFK test paste — cursor insert OK.")
    }

    // MARK: - Permissions

    private func promptAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility required"
        alert.informativeText = """
        AFK needs Accessibility to watch the Fn key and paste into other apps.

        System Settings → Privacy & Security → Accessibility → enable AFK, then click the menu bar icon or relaunch.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
