import Carbon.HIToolbox
import CoreGraphics

enum HotkeyEvent {
    /// Right Option went down.
    case pressed
    /// Right Option came up.
    case released
    /// Another key was pressed while Right Option was held, so this is probably a shortcut.
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

    private var tap: CFMachPort?
    private var isHeld = false

    /// Returns false while Accessibility access has not been granted.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
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
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_RightOption) else { return false }
            let down = event.flags.rawValue & rightOptionDeviceMask != 0
            if down, !isHeld {
                isHeld = true
                if isEnabled { onEvent?(.pressed) }
            } else if !down, isHeld {
                isHeld = false
                if isEnabled { onEvent?(.released) }
            }
            return false

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Int64(kVK_Escape), capturesEscape {
                onEvent?(.escape)
                return true
            }
            if isHeld {
                onEvent?(.keyWhileHeld)
                return false
            }
            let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isEnabled, !isRepeat, code == Int64(kVK_ANSI_V), flags == [.maskCommand, .maskControl] {
                onEvent?(.pasteLast)
                return true
            }
            return false

        default:
            return false
        }
    }
}

/// `NX_DEVICERALTKEYMASK`: tells the right Option key apart from the left one.
private let rightOptionDeviceMask: UInt64 = 0x40

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
