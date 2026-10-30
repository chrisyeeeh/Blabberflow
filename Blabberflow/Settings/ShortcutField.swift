import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click, then press a key: a lone modifier (Right ⌥, fn…) when `allowsModifierKey`, or a key with modifiers.
struct ShortcutField: View {
    /// `nil` means no shortcut; the field then offers to record one and can be cleared again.
    @Binding var shortcut: Shortcut?
    var allowsModifierKey = true
    /// Tells the app to stop listening for the current shortcut while recording.
    var onRecordingChange: (Bool) -> Void = { _ in }
    private let isOptional: Bool

    @State private var recorder = ShortcutRecorder()

    init(shortcut: Binding<Shortcut>, allowsModifierKey: Bool = true, onRecordingChange: @escaping (Bool) -> Void = { _ in }) {
        _shortcut = Binding(get: { shortcut.wrappedValue }, set: { if let value = $0 { shortcut.wrappedValue = value } })
        self.allowsModifierKey = allowsModifierKey
        self.onRecordingChange = onRecordingChange
        isOptional = false
    }

    init(optional shortcut: Binding<Shortcut?>, allowsModifierKey: Bool = true, onRecordingChange: @escaping (Bool) -> Void = { _ in }) {
        _shortcut = shortcut
        self.allowsModifierKey = allowsModifierKey
        self.onRecordingChange = onRecordingChange
        isOptional = true
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if recorder.isRecording {
                    recorder.stop()
                } else {
                    recorder.start(allowsModifierKey: allowsModifierKey) { shortcut = $0 }
                }
            } label: {
                Text(recorder.isRecording ? "Press keys…" : shortcut?.display ?? "Record Shortcut")
                    .monospacedDigit()
                    .frame(minWidth: 110)
            }
            if isOptional, shortcut != nil, !recorder.isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
                .accessibilityLabel("Remove shortcut")
            }
        }
        .onChange(of: recorder.isRecording) { _, recording in onRecordingChange(recording) }
        .onDisappear { recorder.stop() }
        .accessibilityHint("Press to record a new shortcut")
    }
}

@Observable
private final class ShortcutRecorder {
    private(set) var isRecording = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var pendingModifier: UInt16?

    func start(allowsModifierKey: Bool, onRecord: @escaping (Shortcut) -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            self.handle(event, allowsModifierKey: allowsModifierKey, onRecord: onRecord)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingModifier = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent, allowsModifierKey: Bool, onRecord: (Shortcut) -> Void) {
        let modifiers = Shortcut.Modifiers(event.modifierFlags)
        switch event.type {
        case .flagsChanged:
            // A modifier pressed and released on its own becomes the shortcut.
            guard allowsModifierKey, Shortcut.isModifierKey(event.keyCode) else { return }
            let isDown = event.modifierFlags.contains(.function) || !modifiers.isEmpty
            if isDown, pendingModifier == nil {
                pendingModifier = event.keyCode
            } else if !isDown, pendingModifier == event.keyCode {
                onRecord(Shortcut(keyCode: event.keyCode, keyLabel: ""))
                stop()
            } else if isDown {
                pendingModifier = nil // Two modifiers: wait for a real key.
            }
        case .keyDown:
            pendingModifier = nil
            if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
                stop()
                return
            }
            // Plain letters would swallow normal typing, so require a modifier unless it's an F-key.
            guard !modifiers.isEmpty || Shortcut.isFunctionKey(event.keyCode) else {
                NSSound.beep()
                return
            }
            let label = Shortcut.label(for: event.keyCode, characters: event.charactersIgnoringModifiers)
            onRecord(Shortcut(keyCode: event.keyCode, modifiers: modifiers, keyLabel: label))
            stop()
        default:
            break
        }
    }
}
