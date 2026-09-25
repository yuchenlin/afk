import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Modifier keys that must be held exactly for a combo shortcut.
public struct HotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let shift = HotkeyModifiers(rawValue: 1 << 2)
    public static let command = HotkeyModifiers(rawValue: 1 << 3)

    public init(_ flags: CGEventFlags) {
        var m: HotkeyModifiers = []
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        self = m
    }

    public var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.command) { f.insert(.maskCommand) }
        return f
    }

    /// Symbols in the standard macOS menu order: ⌃⌥⇧⌘.
    public var symbols: String {
        (contains(.control) ? "⌃" : "")
            + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "")
            + (contains(.command) ? "⌘" : "")
    }
}

/// The push-to-talk shortcut: hold to record, release to finish.
public enum Hotkey: Codable, Hashable, Sendable {
    case fn
    case combo(keyCode: UInt16, modifiers: HotkeyModifiers)

    public static let commandG = Hotkey.combo(keyCode: UInt16(kVK_ANSI_G), modifiers: .command)
    public static let defaultValue = commandG

    public var displayName: String {
        switch self {
        case .fn:
            return "Fn"
        case let .combo(keyCode, modifiers):
            return modifiers.symbols + Self.keyName(keyCode)
        }
    }

    /// Combos need ⌘, ⌃ or ⌥ (function keys excepted) so ordinary typing never triggers them.
    public var isValid: Bool {
        switch self {
        case .fn:
            return true
        case let .combo(keyCode, modifiers):
            return !modifiers.isDisjoint(with: [.command, .control, .option])
                || Self.functionKeyNames[Int(keyCode)] != nil
        }
    }

    // MARK: - Persistence

    static let defaultsKey = "hotkey"

    public static func load(from defaults: UserDefaults = .standard) -> Hotkey {
        guard let data = defaults.data(forKey: defaultsKey),
              let hotkey = try? JSONDecoder().decode(Hotkey.self, from: data),
              hotkey.isValid
        else { return .defaultValue }
        return hotkey
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Key names

    /// Labels follow the US ANSI layout (key codes are physical positions).
    static func keyName(_ keyCode: UInt16) -> String {
        let code = Int(keyCode)
        return functionKeyNames[code] ?? otherKeyNames[code] ?? "Key \(code)"
    }

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let otherKeyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
}
