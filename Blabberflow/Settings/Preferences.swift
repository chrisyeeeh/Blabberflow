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

/// A tone the transcript is rewritten in by Apple Intelligence, or Literal for exactly what was said.
struct Style: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// What the model is told about the tone. Empty for Literal.
    var instructions: String
    /// Dictates straight into this style, alongside the main dictation shortcut.
    var shortcut: Shortcut?

    var isLiteral: Bool { id == Self.literalID }

    static let literalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let cleanID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    static let builtIn: [Style] = [
        Style(id: literalID, name: "Literal", instructions: ""),
        Style(
            id: cleanID,
            name: "Clean",
            instructions: "Remove filler words (um, uh, like, you know), false starts and repeated words. Apply spoken corrections such as \"no wait, Thursday\". Fix punctuation and capitalisation. Keep the speaker's own words and meaning."
        ),
        Style(
            name: "Formal",
            instructions: "Write it as a polished, professional message: complete sentences, correct grammar, no slang. Keep greetings and sign-offs the speaker said."
        ),
        Style(
            name: "Casual",
            instructions: "Make it friendly and relaxed, like a chat message: drop ums and uhs, contractions are fine, light punctuation, no full stop at the very end."
        ),
        Style(
            name: "Bullet points",
            instructions: "Format it as a bulleted list: split what was said into separate ideas and put each on its own line starting with \"- \". Keep each bullet short and in the speaker's words."
        ),
    ]
}

/// Settings that persist in UserDefaults.
@Observable
final class Preferences {
    var dictationShortcut: Shortcut { didSet { save(dictationShortcut, Key.dictationShortcut) } }
    var pasteLastShortcut: Shortcut { didSet { save(pasteLastShortcut, Key.pasteLastShortcut) } }
    var activationMode: ActivationMode { didSet { save(activationMode, Key.activationMode) } }
    /// Core Audio UID of the chosen input. `nil` follows the system default.
    var microphoneUID: String? { didSet { save(microphoneUID, Key.microphoneUID) } }
    var styles: [Style] { didSet { save(styles, Key.styles) } }
    /// The style the main dictation shortcut uses.
    var defaultStyleID: UUID { didSet { save(defaultStyleID, Key.defaultStyleID) } }
    /// Names, words and acronyms the transcriber should favour and spell exactly.
    var dictionary: [String] { didSet { save(dictionary, Key.dictionary) } }
    var keepsHistory: Bool { didSet { save(keepsHistory, Key.keepsHistory) } }
    /// Days of history to keep; 0 keeps everything.
    var historyRetentionDays: Int { didSet { save(historyRetentionDays, Key.historyRetentionDays) } }
    /// Shows the words above the pill as they're recognised.
    var showsLivePreview: Bool { didSet { save(showsLivePreview, Key.showsLivePreview) } }

    /// Called after any preference changes.
    @ObservationIgnored var onChange: (() -> Void)?

    var defaultStyle: Style {
        styles.first { $0.id == defaultStyleID } ?? styles.first { $0.isLiteral } ?? Style.builtIn[0]
    }

    func style(id: UUID?) -> Style {
        guard let id else { return defaultStyle }
        return styles.first { $0.id == id } ?? defaultStyle
    }

    private enum Key {
        static let dictationShortcut = "dictationShortcut"
        static let pasteLastShortcut = "pasteLastShortcut"
        static let activationMode = "activationMode"
        static let microphoneUID = "microphoneUID"
        static let styles = "styles"
        static let defaultStyleID = "defaultStyleID"
        static let dictionary = "dictionary"
        static let keepsHistory = "keepsHistory"
        static let historyRetentionDays = "historyRetentionDays"
        static let showsLivePreview = "showsLivePreview"
    }

    init() {
        dictationShortcut = Self.load(Key.dictationShortcut) ?? .rightOption
        pasteLastShortcut = Self.load(Key.pasteLastShortcut) ?? .pasteLastDefault
        activationMode = Self.load(Key.activationMode) ?? .hold
        microphoneUID = Self.load(Key.microphoneUID) ?? nil
        var styles: [Style] = Self.load(Key.styles) ?? Style.builtIn
        if !styles.contains(where: \.isLiteral) { styles.insert(Style.builtIn[0], at: 0) }
        // Bring saved built-in prompts up to date, unless the user has edited them.
        let updatedPrompts = [
            "Make it friendly and relaxed, like a chat message: contractions are fine, light punctuation, no full stop at the very end.":
                "Make it friendly and relaxed, like a chat message: drop ums and uhs, contractions are fine, light punctuation, no full stop at the very end.",
        ]
        for index in styles.indices {
            if let updated = updatedPrompts[styles[index].instructions] { styles[index].instructions = updated }
        }
        self.styles = styles
        defaultStyleID = Self.load(Key.defaultStyleID) ?? Style.cleanID
        dictionary = Self.load(Key.dictionary) ?? []
        keepsHistory = Self.load(Key.keepsHistory) ?? true
        historyRetentionDays = Self.load(Key.historyRetentionDays) ?? 30
        showsLivePreview = Self.load(Key.showsLivePreview) ?? false
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
