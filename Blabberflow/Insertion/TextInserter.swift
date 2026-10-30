import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InsertOutcome {
    /// Set directly on the focused field through Accessibility.
    case inserted
    /// Pasted with a synthetic ⌘V (Electron, web views, terminals).
    case pasted
    /// No editable field was focused; the text is on the clipboard.
    case copied
    /// A password field has focus; nothing was inserted.
    case secureField
}

/// Puts text into whatever field has focus in the front app.
final class TextInserter {
    private let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]

    func insert(_ text: String) async -> InsertOutcome {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else {
            copyToClipboard(text)
            return .copied
        }
        if IsSecureEventInputEnabled() { return .secureField }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium and Electron apps only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let element = element(appElement, kAXFocusedUIElementAttribute), isEditable(element) else {
            copyToClipboard(text)
            return .copied
        }
        if string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return .secureField }

        if setSelectedText(text, on: element) { return .inserted }
        await paste(text)
        return .pasted
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Accessibility

    private func isEditable(_ element: AXUIElement) -> Bool {
        if let role = string(element, kAXRoleAttribute), textRoles.contains(role) { return true }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// Replaces the selection. Some apps report success without changing anything,
    /// so the field's value is compared before and after when it can be read.
    private func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        let before = string(element, kAXValueAttribute)
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard result == .success else { return false }
        guard let before else { return true }
        return string(element, kAXValueAttribute) != before
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: Pasteboard fallback

    private func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Tells clipboard managers not to record this entry.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pasteboard.changeCount

        postCommandV()
        try? await Task.sleep(for: .milliseconds(300))

        // Leave the clipboard alone if the user copied something in the meantime.
        guard pasteboard.changeCount == ourChange else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(saved.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        })
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
