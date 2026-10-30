import AppKit
import Observation
import SwiftUI

/// The menu bar item: the app icon while idle, a tiny pill while listening, and a native menu
/// whose header carries the app icon and status.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private lazy var header: NSMenuItem = {
        let item = NSMenuItem()
        let view = NSHostingView(rootView: MenuHeader(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 52)
        item.view = view
        return item
    }()

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
        observeListening()
    }

    // MARK: Icon

    private func updateIcon() {
        let listening = model.isListening
        statusItem.button?.image = listening ? Brand.menuBarPill : Brand.menuBarIcon
        statusItem.button?.setAccessibilityLabel(listening ? "BlabberFlow, listening" : "BlabberFlow")
    }

    private func observeListening() {
        withObservationTracking {
            _ = model.isListening
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.observeListening()
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(header)
        if case .failed = model.speechStatus {
            menu.addItem(item("Retry Speech Model Download", action: #selector(retrySpeech)))
        }
        menu.addItem(.separator())

        let paste = item("Paste Last Transcript", action: #selector(pasteLast))
        paste.isEnabled = !model.recent.isEmpty
        setKeyEquivalent(of: paste, to: model.preferences.pasteLastShortcut)
        menu.addItem(paste)
        let start = item("Start Dictation", action: #selector(startDictation))
        start.attributedTitle = title("Start Dictation", detail: model.preferences.dictationShortcut.display)
        start.isEnabled = model.isReady && !model.isListening
        menu.addItem(start)

        if !model.recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recent"))
            for transcript in model.recent.prefix(3) {
                let text = transcript.text.count > 46 ? transcript.text.prefix(45) + "…" : transcript.text
                let recent = item(String(text), action: #selector(copyRecent(_:)))
                recent.subtitle = caption(for: transcript)
                recent.representedObject = transcript.text
                recent.toolTip = "Click to copy"
                menu.addItem(recent)
            }
        }

        menu.addItem(.separator())
        menu.addItem(microphoneItem())
        menu.addItem(modeItem())
        let pause = item("Pause BlabberFlow", action: #selector(togglePause))
        pause.state = model.isPaused ? .on : .off
        menu.addItem(pause)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(showSettings), key: ","))
        let coffee = item("Buy Me a Coffee…", action: #selector(buyCoffee))
        coffee.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        menu.addItem(coffee)
        menu.addItem(item("Quit BlabberFlow", action: #selector(quit), key: "q"))
    }

    private func microphoneItem() -> NSMenuItem {
        let devices = AudioDevices.inputs()
        let chosenUID = model.preferences.microphoneUID
        let current = AudioDevices.device(uid: chosenUID)
        let defaultName = AudioDevices.defaultInputID().flatMap { id in devices.first { $0.id == id }?.name } ?? "None"

        let parent = item("Microphone", action: nil)
        parent.attributedTitle = title("Microphone", detail: current?.name ?? "None")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let systemDefault = item("System Default", action: #selector(chooseMicrophone(_:)))
        systemDefault.attributedTitle = title("System Default", detail: defaultName, tab: 220)
        systemDefault.state = chosenUID == nil ? .on : .off
        submenu.addItem(systemDefault)
        submenu.addItem(.separator())
        for device in devices {
            let entry = item(device.name, action: #selector(chooseMicrophone(_:)))
            entry.representedObject = device.uid
            entry.state = device.uid == chosenUID ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(item("Sound Settings…", action: #selector(openSoundSettings)))
        parent.submenu = submenu
        return parent
    }

    private func modeItem() -> NSMenuItem {
        let mode = model.preferences.activationMode
        let parent = item("Mode", action: nil)
        parent.attributedTitle = title("Mode", detail: mode == .hold ? "Hold to talk" : "Press to start")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (option, name) in [(ActivationMode.hold, "Hold to Talk"), (.toggle, "Press to Start and Stop")] {
            let entry = item(name, action: #selector(chooseMode(_:)))
            entry.representedObject = option.rawValue
            entry.state = option == mode ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: Actions

    @objc private func pasteLast() { model.pasteLast() }
    @objc private func startDictation() { model.startDictationFromMenu() }
    @objc private func togglePause() { model.isPaused.toggle() }
    @objc private func retrySpeech() { model.retrySpeech() }
    @objc private func showSettings() { openSettings() }
    @objc private func buyCoffee() { NSWorkspace.shared.open(Brand.supportURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        model.copy(text)
    }

    @objc private func chooseMicrophone(_ sender: NSMenuItem) {
        model.preferences.microphoneUID = sender.representedObject as? String
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ActivationMode(rawValue: raw) else { return }
        model.preferences.activationMode = mode
    }

    @objc private func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }

    // MARK: Helpers

    private func item(_ title: String, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// A title with secondary text right-aligned before the submenu arrow or edge, e.g. "Microphone   Shure MV7".
    private func title(_ title: String, detail: String, tab: CGFloat = 250) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: tab)]
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: title + "\t", attributes: [.font: font, .paragraphStyle: style])
        text.append(NSAttributedString(string: detail, attributes: [
            .font: font, .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }

    private func setKeyEquivalent(of item: NSMenuItem, to shortcut: Shortcut) {
        guard !shortcut.isModifierKey, shortcut.keyLabel.count == 1 else { return }
        item.keyEquivalent = shortcut.keyLabel.lowercased()
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { mask.insert(.command) }
        if shortcut.modifiers.contains(.control) { mask.insert(.control) }
        if shortcut.modifiers.contains(.option) { mask.insert(.option) }
        if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
        item.keyEquivalentModifierMask = mask
    }

    private func caption(for transcript: Transcript) -> String {
        let time = transcript.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        guard let app = transcript.appName else { return time }
        return "\(app) · \(time)"
    }
}

/// The menu's first row: a small app icon with a status dot, the status and how to dictate.
private struct MenuHeader: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            AppIconTile(size: 30)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(model.isReady ? Color.green : Color.yellow)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(model.statusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 300, height: 52, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
