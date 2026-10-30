import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum HotkeyEvent {
    /// A dictation shortcut went down. `style` is set for a style's own shortcut, `nil` for the main one.
    case pressed(style: UUID?)
    /// The held dictation shortcut came up.
    case released
    /// Another key was pressed while a modifier-key shortcut was held, so this is probably an ordinary shortcut.
    case keyWhileHeld
    case escape
    case pasteLast
}

/// A shortcut that starts dictation, optionally in a particular style.
struct DictationBinding: Equatable {
    var shortcut: Shortcut
    var style: UUID?
}

/// Watches the keyboard through a Core Graphics event tap. Needs Accessibility permission.
final class HotkeyMonitor {
    var onEvent: ((HotkeyEvent) -> Void)?
    var isEnabled = true
    /// When true, Escape is consumed instead of reaching the front app.
    var capturesEscape = false
    /// The main shortcut first, then each style's. The first binding for a shortcut wins.
    var bindings: [DictationBinding] = [DictationBinding(shortcut: .rightOption)] {
        didSet { held = nil }
    }
    var pasteLastShortcut = Shortcut.pasteLastDefault

    private var tap: CFMachPort?
    /// The binding whose key is down right now.
    private var held: DictationBinding?

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

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .flagsChanged:
            if let held, held.shortcut.isModifierKey {
                guard code == held.shortcut.keyCode, let mask = held.shortcut.deviceMask else { return false }
                if event.flags.rawValue & mask == 0 { release() }
                return false
            }
            guard held == nil,
                  let binding = bindings.first(where: { $0.shortcut.isModifierKey && $0.shortcut.keyCode == code }),
                  let mask = binding.shortcut.deviceMask,
                  event.flags.rawValue & mask != 0 else { return false }
            press(binding)
            return false

        case .keyDown:
            let modifiers = Shortcut.Modifiers(event.flags)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if code == UInt16(kVK_Escape), modifiers.isEmpty, capturesEscape {
                onEvent?(.escape)
                return true
            }
            if let binding = bindings.first(where: {
                !$0.shortcut.isModifierKey && $0.shortcut.keyCode == code && $0.shortcut.modifiers == modifiers
            }) {
                if !isRepeat, held == nil { press(binding) }
                return isEnabled
            }
            if let held, held.shortcut.isModifierKey {
                if isEnabled { onEvent?(.keyWhileHeld) }
                return false
            }
            if isEnabled, !isRepeat, code == pasteLastShortcut.keyCode, modifiers == pasteLastShortcut.modifiers {
                onEvent?(.pasteLast)
                return true
            }
            return false

        case .keyUp:
            guard let held, !held.shortcut.isModifierKey, code == held.shortcut.keyCode else { return false }
            release()
            return isEnabled

        default:
            return false
        }
    }

    private func press(_ binding: DictationBinding) {
        held = binding
        if isEnabled { onEvent?(.pressed(style: binding.style)) }
    }

    private func release() {
        held = nil
        if isEnabled { onEvent?(.released) }
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
