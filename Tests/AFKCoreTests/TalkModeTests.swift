import Carbon.HIToolbox
import XCTest
@testable import AFKCore

final class TalkModeTests: XCTestCase {
    private let esc = UInt16(kVK_Escape)
    private let g = UInt16(kVK_ANSI_G)

    // MARK: - Esc interception

    func testEscapePassesThroughUnlessIntercepting() {
        var t = HotkeyTracker(hotkey: .defaultValue)
        XCTAssertEqual(t.handle(.keyDown(keyCode: esc, modifiers: [], isRepeat: false)), .pass)
        XCTAssertEqual(t.handle(.keyUp(keyCode: esc)), .pass)
    }

    func testEscapeInterceptedDuringHandsFree() {
        var t = HotkeyTracker(hotkey: .defaultValue)
        t.interceptsEscape = true
        XCTAssertEqual(t.handle(.keyDown(keyCode: esc, modifiers: [], isRepeat: false)), .suppress(.escapePressed))
        XCTAssertEqual(t.handle(.keyUp(keyCode: esc)), .swallow, "matching release is consumed too")
        XCTAssertEqual(t.handle(.keyDown(keyCode: esc, modifiers: .command, isRepeat: false)), .pass, "⌘Esc is left alone")
    }

    func testShortcutStillWorksWhileIntercepting() {
        var t = HotkeyTracker(hotkey: .defaultValue)
        t.interceptsEscape = true
        XCTAssertEqual(t.handle(.keyDown(keyCode: g, modifiers: .command, isRepeat: false)), .suppress(.began))
        XCTAssertEqual(t.handle(.keyUp(keyCode: g)), .suppress(.ended))
    }

    // MARK: - Pause detection

    func testAutoStopAfterPauseOnlyOnceSpeechStarted() {
        let t0 = Date()
        var d = PauseDetector(startedAt: t0)
        XCTAssertFalse(d.shouldStop(at: t0.addingTimeInterval(5), autoStop: true), "no speech yet, under 10 s")
        d.transcriptChanged(to: "hello", at: t0.addingTimeInterval(5))
        XCTAssertFalse(d.shouldStop(at: t0.addingTimeInterval(7), autoStop: true))
        d.transcriptChanged(to: "hello", at: t0.addingTimeInterval(7))  // unchanged text isn't activity
        XCTAssertTrue(d.shouldStop(at: t0.addingTimeInterval(7.6), autoStop: true))
        XCTAssertFalse(d.shouldStop(at: t0.addingTimeInterval(7.6), autoStop: false), "pause rule needs auto-stop")
    }

    func testNewSpeechResetsPause() {
        let t0 = Date()
        var d = PauseDetector(startedAt: t0)
        d.transcriptChanged(to: "one", at: t0.addingTimeInterval(1))
        d.transcriptChanged(to: "one two", at: t0.addingTimeInterval(3))
        XCTAssertFalse(d.shouldStop(at: t0.addingTimeInterval(5), autoStop: true))
        XCTAssertTrue(d.shouldStop(at: t0.addingTimeInterval(5.6), autoStop: true))
    }

    func testNoSpeechTimeoutAndMaxDuration() {
        let t0 = Date()
        let d = PauseDetector(startedAt: t0)
        XCTAssertTrue(d.shouldStop(at: t0.addingTimeInterval(10), autoStop: true))
        XCTAssertFalse(d.shouldStop(at: t0.addingTimeInterval(10), autoStop: false))
        XCTAssertTrue(d.shouldStop(at: t0.addingTimeInterval(300), autoStop: false), "5-minute cap always applies")
    }

    // MARK: - Settings

    func testSettingsPersistence() throws {
        let suite = "afk.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(TalkSettings.load(from: defaults), TalkSettings(), "defaults: hold, no auto-stop, system mic")

        var s = TalkSettings()
        s.mode = .handsFree
        s.autoStopAfterPause = true
        s.inputDeviceUID = "BuiltInMicrophoneDevice"
        s.save(to: defaults)
        XCTAssertEqual(TalkSettings.load(from: defaults), s)

        s.inputDeviceUID = nil
        s.save(to: defaults)
        XCTAssertNil(TalkSettings.load(from: defaults).inputDeviceUID)
    }

    // MARK: - Devices

    func testInputDevicesAreListedWithUniqueUIDs() throws {
        let devices = AudioDevices.inputDevices()
        try XCTSkipIf(devices.isEmpty, "no audio input devices on this machine")
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count)
        for device in devices {
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertEqual(AudioDevices.device(uid: device.uid), device)
        }
        if let def = AudioDevices.defaultInputDevice() {
            XCTAssertTrue(devices.contains(def), "default input is among the listed inputs")
        }
        print("input devices:", devices.map(\.name))
    }
}
