import AppKit
import Carbon.HIToolbox
import Observation

enum ActivationMode: String, Codable, CaseIterable {
    /// Hold the shortcut while speaking; letting go inserts.
    case hold
    /// Press once to start, press again to insert.
    case toggle
}

/// A dictation or paste shortcut: either a lone modifier key (Right ⌥, Fn…) or a key with modifiers (⌃⌥Space).
struct Shortcut: Codable, Hashable {
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        init(rawValue: Int) { self.rawValue = rawValue }

        init(_ flags: NSEvent.ModifierFlags) {
            var modifiers = Modifiers()
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.command) }
            self = modifiers
        }

        init(_ flags: CGEventFlags) {
            var modifiers = Modifiers()
            if flags.contains(.maskControl) { modifiers.insert(.control) }
            if flags.contains(.maskAlternate) { modifiers.insert(.option) }
            if flags.contains(.maskShift) { modifiers.insert(.shift) }
            if flags.contains(.maskCommand) { modifiers.insert(.command) }
            self = modifiers
        }

        var symbols: String {
            (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
                + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
        }
    }

    /// Virtual key code (`kVK_…`).
    var keyCode: UInt16
    /// Held together with the key. Empty for a lone modifier key.
    var modifiers: Modifiers = []
    /// What the key itself is called, captured when the shortcut was recorded.
    var keyLabel: String

    var isModifierKey: Bool { Self.modifierKeys[keyCode] != nil }

    var display: String {
        if let key = Self.modifierKeys[keyCode] { return key.name }
        return modifiers.symbols + keyLabel
    }

    /// The `CGEventFlags` bit that tells whether this modifier key, on this side of the keyboard, is down.
    var deviceMask: UInt64? { Self.modifierKeys[keyCode]?.mask }

    static let rightOption = Shortcut(keyCode: UInt16(kVK_RightOption), keyLabel: "")
    static let rightCommand = Shortcut(keyCode: UInt16(kVK_RightCommand), keyLabel: "")
    static let rightShift = Shortcut(keyCode: UInt16(kVK_RightShift), keyLabel: "")
    static let function = Shortcut(keyCode: UInt16(kVK_Function), keyLabel: "")
    static let pasteLastDefault = Shortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.control, .command], keyLabel: "V")

    /// Single modifier keys offered as presets.
    static let presets: [Shortcut] = [.rightOption, .rightCommand, .rightShift, .function]

    private static let modifierKeys: [UInt16: (name: String, mask: UInt64)] = [
        UInt16(kVK_RightOption): ("Right ⌥", 0x40),
        UInt16(kVK_Option): ("Left ⌥", 0x20),
        UInt16(kVK_RightCommand): ("Right ⌘", 0x10),
        UInt16(kVK_Command): ("Left ⌘", 0x08),
        UInt16(kVK_RightShift): ("Right ⇧", 0x04),
        UInt16(kVK_Shift): ("Left ⇧", 0x02),
        UInt16(kVK_RightControl): ("Right ⌃", 0x2000),
        UInt16(kVK_Control): ("Left ⌃", 0x01),
        UInt16(kVK_Function): ("fn", CGEventFlags.maskSecondaryFn.rawValue),
    ]

    static func isModifierKey(_ keyCode: UInt16) -> Bool { modifierKeys[keyCode] != nil }

    /// A readable name for keys whose character isn't useful (Space, F5, arrows…).
    static func label(for keyCode: UInt16, characters: String?) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        if let name = named[Int(keyCode)] { return name }
        return (characters ?? "?").uppercased()
    }

    /// F-keys work as shortcuts on their own; other keys need a modifier so normal typing isn't swallowed.
    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11,
         kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            .contains(Int(keyCode))
    }
}

/// Settings that persist in UserDefaults.
@Observable
final class Preferences {
    var dictationShortcut: Shortcut { didSet { save(dictationShortcut, Key.dictationShortcut) } }
    var pasteLastShortcut: Shortcut { didSet { save(pasteLastShortcut, Key.pasteLastShortcut) } }
    var activationMode: ActivationMode { didSet { save(activationMode, Key.activationMode) } }
    /// Core Audio UID of the chosen input. `nil` follows the system default.
    var microphoneUID: String? { didSet { save(microphoneUID, Key.microphoneUID) } }

    /// Called after any preference changes.
    @ObservationIgnored var onChange: (() -> Void)?

    private enum Key {
        static let dictationShortcut = "dictationShortcut"
        static let pasteLastShortcut = "pasteLastShortcut"
        static let activationMode = "activationMode"
        static let microphoneUID = "microphoneUID"
    }

    init() {
        dictationShortcut = Self.load(Key.dictationShortcut) ?? .rightOption
        pasteLastShortcut = Self.load(Key.pasteLastShortcut) ?? .pasteLastDefault
        activationMode = Self.load(Key.activationMode) ?? .hold
        microphoneUID = Self.load(Key.microphoneUID) ?? nil
    }

    private func save<Value: Encodable>(_ value: Value, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
        onChange?()
    }

    private static func load<Value: Decodable>(_ key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}
