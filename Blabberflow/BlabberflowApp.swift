import SwiftUI

@main struct BlabberflowApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

/// Lives for the whole session, so it also opens Settings when the Dock icon is clicked.
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: model.isListening ? "waveform.circle.fill" : "waveform")
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.dockIconClicked)) { _ in
                openSettings()
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let dockIconClicked = Notification.Name("BlabberflowDockIconClicked")

    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: Self.dockIconClicked, object: nil) }
        return true
    }
}
