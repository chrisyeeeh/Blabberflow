import SwiftUI

@main struct BlabberflowApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // The menu bar item and the Settings window are AppKit-managed (see AppDelegate);
        // this scene only supplies the app menu's Settings… command.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.showSettings() }
                        .keyboardShortcut(",")
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusMenu: StatusMenuController?
    private lazy var settingsWindow = SettingsWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        statusMenu = StatusMenuController(model: model) { [weak self] in self?.showSettings() }
    }

    /// Clicking the Dock icon opens Settings, since there's no main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    func showSettings() {
        settingsWindow.show()
    }
}

/// Owns the Settings window so the Dock icon, the menu bar menu and ⌘, can all open it.
final class SettingsWindowController {
    private let window: NSWindow

    init(model: AppModel) {
        window = NSWindow(contentViewController: NSHostingController(rootView: SettingsWindow(model: model)))
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Blabberflow Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Settings")
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
