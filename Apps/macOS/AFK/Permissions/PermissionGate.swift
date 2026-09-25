import AVFoundation
import ApplicationServices

struct PermissionGate {
    func ensureForDictation() -> Bool {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        var micOK = mic == .authorized
        if mic == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                micOK = ok
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 30)
        }
        let axOK = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        return micOK && axOK
    }
}
