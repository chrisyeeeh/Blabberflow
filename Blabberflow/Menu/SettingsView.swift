import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Dictate", value: "Hold right ⌥")
                LabeledContent("Cancel", value: "Esc")
                LabeledContent("Paste last transcript", value: "⌃⌘V")
            }
            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    granted: model.hasMicrophone,
                    pane: "Privacy_Microphone"
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "Needed for the hotkey and to type into other apps.",
                    granted: model.hasAccessibility,
                    pane: "Privacy_Accessibility"
                )
            }
            Section("Speech") {
                LabeledContent("On-device model") {
                    switch model.speechStatus {
                    case .preparing: ProgressView().controlSize(.small)
                    case .ready: Text("Ready")
                    case .failed(let reason): Text(reason).foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    var detail: String?
    let granted: Bool
    let pane: String

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Open System Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}
