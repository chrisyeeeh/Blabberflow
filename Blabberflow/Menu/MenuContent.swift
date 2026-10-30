import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusLine)
        Divider()
        Button("Paste Last Transcript") { model.pasteLast() }
            .keyboardShortcut("v", modifiers: [.control, .command])
            .disabled(model.recent.isEmpty)
        if !model.recent.isEmpty {
            Section("Recent — click to copy") {
                ForEach(Array(model.recent.prefix(3).enumerated()), id: \.offset) { _, text in
                    Button(text.count > 48 ? text.prefix(47) + "…" : text) { model.copy(text) }
                }
            }
        }
        Divider()
        Toggle("Pause Blabberflow", isOn: $model.isPaused)
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Blabberflow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
