import Foundation

/// Thin wrapper around Darwin (CF) distributed notifications for App Group IPC.
public enum DarwinNotify {
    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    /// Observe a Darwin notification. Returns a token; pass it to `stop(_:)`.
    @discardableResult
    public static func observe(_ name: String, handler: @escaping () -> Void) -> NSObjectProtocol {
        let proxy = ObserverProxy(name: name, handler: handler)
        proxy.start()
        return proxy
    }

    public static func stop(_ token: NSObjectProtocol) {
        (token as? ObserverProxy)?.stop()
    }
}

private final class ObserverProxy: NSObject {
    let name: String
    let handler: () -> Void
    private var listening = false

    init(name: String, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
    }

    func start() {
        guard !listening else { return }
        listening = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let proxy = Unmanaged<ObserverProxy>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { proxy.handler() }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    func stop() {
        guard listening else { return }
        listening = false
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }

    deinit { stop() }
}
