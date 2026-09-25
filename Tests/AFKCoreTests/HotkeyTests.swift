import Carbon.HIToolbox
import XCTest
@testable import AFKCore

final class HotkeyTests: XCTestCase {
    private let g = UInt16(kVK_ANSI_G)
    private let k = UInt16(kVK_ANSI_K)
    private let esc = UInt16(kVK_Escape)

    // MARK: - Hotkey

    func testDefaultIsCommandG() {
        XCTAssertEqual(Hotkey.defaultValue, .combo(keyCode: g, modifiers: .command))
        XCTAssertEqual(Hotkey.defaultValue.displayName, "⌘G")
    }

    func testDisplayNames() {
        XCTAssertEqual(Hotkey.fn.displayName, "Fn")
        let hotkey = Hotkey.combo(keyCode: UInt16(kVK_Space), modifiers: [.command, .option, .control, .shift])
        XCTAssertEqual(hotkey.displayName, "⌃⌥⇧⌘Space")
        XCTAssertEqual(Hotkey.combo(keyCode: UInt16(kVK_F5), modifiers: []).displayName, "F5")
    }

    func testValidity() {
        XCTAssertTrue(Hotkey.fn.isValid)
        XCTAssertTrue(Hotkey.defaultValue.isValid)
        XCTAssertTrue(Hotkey.combo(keyCode: UInt16(kVK_F5), modifiers: []).isValid)
        XCTAssertFalse(Hotkey.combo(keyCode: g, modifiers: []).isValid)
        XCTAssertFalse(Hotkey.combo(keyCode: g, modifiers: .shift).isValid)
    }

    func testPersistence() throws {
        let suite = "afk.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(Hotkey.load(from: defaults), .defaultValue)

        let custom = Hotkey.combo(keyCode: k, modifiers: [.control, .option])
        custom.save(to: defaults)
        XCTAssertEqual(Hotkey.load(from: defaults), custom)

        Hotkey.fn.save(to: defaults)
        XCTAssertEqual(Hotkey.load(from: defaults), .fn)

        Hotkey.combo(keyCode: g, modifiers: []).save(to: defaults)
        XCTAssertEqual(Hotkey.load(from: defaults), .defaultValue, "invalid stored shortcut falls back")
    }

    // MARK: - Tracker: combo

    func testComboHoldBeginsAndEnds() {
        var t = HotkeyTracker(hotkey: .defaultValue)
        XCTAssertEqual(t.handle(.keyDown(keyCode: g, modifiers: .command, isRepeat: false)), .suppress(.began))
        XCTAssertEqual(t.handle(.keyDown(keyCode: g, modifiers: .command, isRepeat: true)), .swallow)
        XCTAssertEqual(t.handle(.keyUp(keyCode: g)), .suppress(.ended))
        XCTAssertFalse(t.isActive)
    }

    func testComboEndsEvenIfModifierReleasedFirst() {
        var t = HotkeyTracker(hotkey: .defaultValue)
        _ = t.handle(.keyDown(keyCode: g, modifiers: .command, isRepeat: false))
        XCTAssertEqual(t.handle(.flagsChanged(fn: false)), .pass)
        XCTAssertEqual(t.handle(.keyUp(keyCode: g)), .suppress(.ended))
    }

    func testComboRequiresExactModifiers() {
        var t = HotkeyTracker(hotkey: .defaultValue)
        XCTAssertEqual(t.handle(.keyDown(keyCode: g, modifiers: [], isRepeat: false)), .pass)
        XCTAssertEqual(t.handle(.keyDown(keyCode: g, modifiers: [.command, .shift], isRepeat: false)), .pass)
        XCTAssertEqual(t.handle(.keyDown(keyCode: k, modifiers: .command, isRepeat: false)), .pass)
        XCTAssertEqual(t.handle(.keyUp(keyCode: g)), .pass)
        XCTAssertEqual(t.handle(.flagsChanged(fn: true)), .pass, "Fn is ignored when the shortcut is a combo")
    }

    func testDisabledPassesEverything() {
        var t = HotkeyTracker(hotkey: .defaultValue)
        t.isEnabled = false
        XCTAssertEqual(t.handle(.keyDown(keyCode: g, modifiers: .command, isRepeat: false)), .pass)
    }

    func testReleaseStillDeliveredAfterDisablingMidHold() {
        var t = HotkeyTracker(hotkey: .defaultValue)
        _ = t.handle(.keyDown(keyCode: g, modifiers: .command, isRepeat: false))
        t.isEnabled = false
        XCTAssertEqual(t.handle(.keyUp(keyCode: g)), .suppress(.ended))
    }

    // MARK: - Tracker: Fn

    func testFnHold() {
        var t = HotkeyTracker(hotkey: .fn)
        XCTAssertEqual(t.handle(.flagsChanged(fn: true)), .suppress(.began))
        XCTAssertEqual(t.handle(.flagsChanged(fn: true)), .pass)
        XCTAssertEqual(t.handle(.flagsChanged(fn: false)), .suppress(.ended))
        XCTAssertEqual(t.handle(.keyDown(keyCode: g, modifiers: .command, isRepeat: false)), .pass)
    }

    // MARK: - Tracker: recording

    func testRecordCombo() {
        var t = HotkeyTracker(hotkey: .defaultValue)
        t.startRecording()
        XCTAssertEqual(t.handle(.flagsChanged(fn: false)), .pass)
        XCTAssertEqual(t.handle(.keyDown(keyCode: k, modifiers: [], isRepeat: false)), .suppress(.recordingRejected))
        XCTAssertTrue(t.isRecording)
        let expected = Hotkey.combo(keyCode: k, modifiers: [.control, .option])
        XCTAssertEqual(
            t.handle(.keyDown(keyCode: k, modifiers: [.control, .option], isRepeat: false)),
            .suppress(.recorded(expected))
        )
        XCTAssertFalse(t.isRecording)
        XCTAssertEqual(t.handle(.keyUp(keyCode: k)), .swallow, "release of the recorded key is consumed")
        XCTAssertEqual(t.handle(.keyUp(keyCode: k)), .pass)
    }

    func testRecordFn() {
        var t = HotkeyTracker(hotkey: .defaultValue)
        t.startRecording()
        XCTAssertEqual(t.handle(.flagsChanged(fn: true)), .suppress(.recorded(.fn)))
        t.hotkey = .fn
        XCTAssertEqual(t.handle(.flagsChanged(fn: false)), .swallow, "Fn release after recording doesn't end a hold")
        XCTAssertEqual(t.handle(.flagsChanged(fn: true)), .suppress(.began))
    }

    func testEscapeCancelsRecording() {
        var t = HotkeyTracker(hotkey: .defaultValue)
        t.startRecording()
        XCTAssertEqual(t.handle(.keyDown(keyCode: esc, modifiers: [], isRepeat: false)), .suppress(.recordingCancelled))
        XCTAssertFalse(t.isRecording)
        XCTAssertEqual(t.handle(.keyUp(keyCode: esc)), .swallow)
        XCTAssertEqual(t.hotkey, .defaultValue)
    }
}
