import ServiceManagement
import SwiftData
import SwiftUI

/// The app's window, laid out like System Settings: a sidebar of panes and grouped forms.
struct SettingsWindow: View {
    let model: AppModel
    @State private var pane: Pane? = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general, shortcuts, styles, dictionary, history, insights, privacy

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            case .styles: "Styles"
            case .dictionary: "Dictionary"
            case .history: "History"
            case .insights: "Insights"
            case .privacy: "Privacy"
            }
        }

        /// SF Symbol for the tile's glyph; General draws the app's pill instead.
        var symbol: String? {
            switch self {
            case .general: nil
            case .shortcuts: "option"
            case .styles: "paintbrush.pointed"
            case .dictionary: "character.book.closed"
            case .history: "clock"
            case .insights: "chart.bar.xaxis"
            case .privacy: "checkmark.shield"
            }
        }

        /// Top and bottom of the tile's gradient, top-lit like the app icon.
        var gradient: [Color] {
            switch self {
            case .general: [Color(red: 0.48, green: 0.42, blue: 1.00), Color(red: 0.20, green: 0.10, blue: 0.62)]
            case .shortcuts: [Color(red: 0.60, green: 0.60, blue: 0.63), Color(red: 0.29, green: 0.29, blue: 0.31)]
            case .styles: [Color(red: 0.82, green: 0.49, blue: 1.00), Color(red: 0.54, green: 0.21, blue: 0.83)]
            case .dictionary: [Color(red: 1.00, green: 0.72, blue: 0.30), Color(red: 0.94, green: 0.45, blue: 0.06)]
            case .history: [Color(red: 0.37, green: 0.86, blue: 0.48), Color(red: 0.12, green: 0.60, blue: 0.25)]
            case .insights: [Color(red: 0.31, green: 0.83, blue: 0.86), Color(red: 0.06, green: 0.56, blue: 0.62)]
            case .privacy: [Color(red: 0.31, green: 0.66, blue: 1.00), Color(red: 0.04, green: 0.37, blue: 0.78)]
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SidebarTile(colors: pane.gradient) {
                        if let symbol = pane.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        } else {
                            PillGlyph(filled: false).padding(2)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch pane ?? .general {
            case .general: GeneralPane(model: model)
            case .shortcuts: ShortcutsPane(model: model)
            case .styles: StylesPane(model: model)
            case .dictionary: DictionaryPane(model: model)
            case .history: HistoryPane(model: model)
            case .insights: InsightsPane(model: model)
            case .privacy: PrivacyPane(model: model)
            }
        }
        .frame(width: 960, height: 640)
        .modelContainer(model.history.container)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}

/// A sidebar icon: a 22 pt tile with a top-lit gradient and a white glyph, one family with the app icon.
struct SidebarTile<Glyph: View>: View {
    let colors: [Color]
    var size: CGFloat = 22
    @ViewBuilder let glyph: Glyph

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        shape
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.4), .clear, .black.opacity(0.14)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5
                )
            }
            .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
            .overlay { glyph }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Large title and subtitle above a grouped form, as in the design handoff.
struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)

            Form { content }
                .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("")
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var model: AppModel
    @State private var microphones: [AudioInputDevice] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var levelMonitor = MicLevelMonitor()

    var body: some View {
        @Bindable var preferences = model.preferences
        Page(title: "General", subtitle: "Blabberflow runs entirely on this Mac. Nothing you say leaves it.") {
            Section("Microphone") {
                Picker("Input", selection: $preferences.microphoneUID) {
                    Text("System default — \(defaultMicrophoneName)").tag(String?.none)
                    Divider()
                    ForEach(microphones) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                if let uid = model.preferences.microphoneUID, !microphones.contains(where: { $0.uid == uid }) {
                    Label("That microphone isn't connected, so the system default is used.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.multicolor)
                }
                LabeledContent("Level") {
                    HStack(spacing: 12) {
                        LevelMeter(level: levelMonitor.level)
                        Button(levelMonitor.isRunning ? "Stop" : "Test") {
                            if levelMonitor.isRunning {
                                levelMonitor.stop()
                            } else {
                                levelMonitor.start(deviceUID: model.preferences.microphoneUID)
                            }
                        }
                    }
                }
            }

            Section("Dictation") {
                Toggle(isOn: $preferences.showsLivePreview) {
                    Text("Show live preview")
                    Text("See the words above the pill as you speak.")
                }
            }

            Section("On-device models") {
                LabeledContent {
                    switch model.speechStatus {
                    case .preparing: ProgressView().controlSize(.small)
                    case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let reason): Text(reason).foregroundStyle(.orange)
                    }
                } label: {
                    Text("Speech recognition")
                    Text("Turns your voice into text. Works with Apple Intelligence on or off.")
                }
                AppleIntelligenceRow(status: model.appleIntelligence)
            }

            Section("Startup") {
                Toggle("Open Blabberflow when you log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            }

            Section("Support") {
                LabeledContent {
                    Link("Buy Me a Coffee", destination: Brand.supportURL)
                } label: {
                    HStack(spacing: 12) {
                        SidebarTile(colors: [Color(red: 1.00, green: 0.60, blue: 0.48), Color(red: 0.85, green: 0.31, blue: 0.18)], size: 28) {
                            Image(systemName: "cup.and.saucer")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Enjoying Blabberflow?")
                            Text("Made by one person, not sold on the App Store. A coffee helps.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onChange(of: model.preferences.microphoneUID) { _, uid in
            if levelMonitor.isRunning { levelMonitor.restart(deviceUID: uid) }
        }
        .onDisappear { levelMonitor.stop() }
        .task {
            // Microphones come and go (USB, iPhone Continuity), so keep the list fresh while visible.
            while !Task.isCancelled {
                microphones = AudioDevices.inputs()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var defaultMicrophoneName: String {
        guard let id = AudioDevices.defaultInputID() else { return "none" }
        return microphones.first { $0.id == id }?.name ?? "none"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Apple Intelligence status, with a way to turn it on when it's off.
struct AppleIntelligenceRow: View {
    let status: AppleIntelligenceStatus

    var body: some View {
        LabeledContent {
            switch status {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .preparing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading").foregroundStyle(.secondary)
                }
            case .off:
                Button("Turn On in System Settings…") { NSWorkspace.shared.open(AppleIntelligenceStatus.settingsURL) }
            case .unsupported:
                Text("Not available on this Mac").foregroundStyle(.secondary)
            }
        } label: {
            Text("Apple Intelligence")
            Text(status == .unsupported
                 ? "Styles insert what you said without rewriting."
                 : "Rewrites what you said in the style you pick.")
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var preferences = model.preferences
        Page(title: "Shortcuts", subtitle: "Choose the key that starts dictation and how it behaves.") {
            Section("Dictation") {
                LabeledContent("Shortcut") {
                    HStack {
                        Menu {
                            ForEach(Shortcut.presets, id: \.self) { preset in
                                Button(preset.display) { model.preferences.dictationShortcut = preset }
                            }
                        } label: {
                            Text("Presets")
                        }
                        .fixedSize()
                        ShortcutField(shortcut: $preferences.dictationShortcut) { model.isRecordingShortcut = $0 }
                    }
                }

                Picker("Mode", selection: $preferences.activationMode) {
                    VStack(alignment: .leading) {
                        Text("Hold to talk")
                        Text("Hold the shortcut while you speak. Let go to insert.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(ActivationMode.hold)
                    VStack(alignment: .leading) {
                        Text("Press to start and stop")
                        Text("Press once to start, again to insert. Esc cancels.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(ActivationMode.toggle)
                }
                .pickerStyle(.radioGroup)

                if model.preferences.dictationShortcut == .function {
                    Label(
                        "Set “Press 🌐 key to” to Do Nothing in System Settings › Keyboard, so fn doesn't also start Apple's dictation.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            Section("Other") {
                LabeledContent("Paste last transcript") {
                    ShortcutField(shortcut: $preferences.pasteLastShortcut, allowsModifierKey: false) {
                        model.isRecordingShortcut = $0
                    }
                }
                LabeledContent("Cancel dictation", value: "Esc")
            }

            Section {
                Text("Each style can have its own shortcut too, so one key dictates formally and another casually. Set them in Styles.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    let model: AppModel

    var body: some View {
        Page(title: "Privacy", subtitle: "Speech is turned into text by Apple's on-device model. No account, no servers.") {
            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    detail: model.hasMicrophone ? "Allowed" : "Needed to hear you",
                    granted: model.hasMicrophone,
                    pane: "Privacy_Microphone"
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: model.hasAccessibility
                        ? "Allowed"
                        : "Turn on Blabberflow in Privacy & Security › Accessibility",
                    granted: model.hasAccessibility,
                    pane: "Privacy_Accessibility"
                )
            }
            Section("Why Accessibility?") {
                Text("Blabberflow uses it to notice your dictation shortcut in any app and to type the result where your cursor is. It only acts while you're dictating.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let pane: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open System Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}
