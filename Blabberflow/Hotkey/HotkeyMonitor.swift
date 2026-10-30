import Carbon.HIToolbox
import CoreGraphics

enum HotkeyEvent {
    /// The dictation shortcut went down.
    case pressed
    /// The dictation shortcut came up.
    case released
    /// Another key was pressed while a modifier-key shortcut was held, so this is probably an ordinary shortcut.
    case keyWhileHeld
    case escape
    case pasteLast
}

/// Watches the keyboard through a Core Graphics event tap. Needs Accessibility permission.
final class HotkeyMonitor {
    var onEvent: ((HotkeyEvent) -> Void)?
    var isEnabled = true
    /// When true, Escape is consumed instead of reaching the front app.
    var capturesEscape = false
    var dictationShortcut = Shortcut.rightOption {
        didSet { isHeld = false }
    }
    var pasteLastShortcut = Shortcut.pasteLastDefault

    private var tap: CFMachPort?
    private var isHeld = false

    /// Returns false while Accessibility access has not been granted.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// Returns true when the event should be swallowed.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcut = dictationShortcut

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .flagsChanged:
            guard code == shortcut.keyCode, let mask = shortcut.deviceMask else { return false }
            setHeld(event.flags.rawValue & mask != 0)
            return false

        case .keyDown:
            let modifiers = Shortcut.Modifiers(event.flags)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if code == UInt16(kVK_Escape), modifiers.isEmpty, capturesEscape {
                onEvent?(.escape)
                return true
            }
            if !shortcut.isModifierKey, code == shortcut.keyCode, modifiers == shortcut.modifiers {
                if !isRepeat { setHeld(true) }
                return isEnabled
            }
            if isHeld, shortcut.isModifierKey {
                if isEnabled { onEvent?(.keyWhileHeld) }
                return false
            }
            if isEnabled, !isRepeat, code == pasteLastShortcut.keyCode, modifiers == pasteLastShortcut.modifiers {
                onEvent?(.pasteLast)
                return true
            }
            return false

        case .keyUp:
            guard !shortcut.isModifierKey, code == shortcut.keyCode, isHeld else { return false }
            setHeld(false)
            return isEnabled

        default:
            return false
        }
    }

    private func setHeld(_ down: Bool) {
        guard down != isHeld else { return }
        isHeld = down
        if isEnabled { onEvent?(down ? .pressed : .released) }
    }
}

nonisolated private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    // The tap's run loop source is on the main run loop, so these never leave the main thread.
    nonisolated(unsafe) let event = event
    nonisolated(unsafe) let pointer = refcon
    let swallow = MainActor.assumeIsolated {
        Unmanaged<HotkeyMonitor>.fromOpaque(pointer).takeUnretainedValue().handle(type, event)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
