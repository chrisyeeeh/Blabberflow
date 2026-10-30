import SwiftUI

/// The menu bar dropdown, styled like the app icon: the pill on an indigo-to-violet gradient.
struct MenuPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider().overlay(.white.opacity(0.2))

            VStack(alignment: .leading, spacing: 0) {
                MenuRow(title: "Paste Last Transcript", shortcut: "⌃⌘V") {
                    closeMenu()
                    model.pasteLast()
                }
                .disabled(model.recent.isEmpty)

                if !model.recent.isEmpty {
                    Text("Recent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    ForEach(model.recent.prefix(3)) { transcript in
                        RecentRow(transcript: transcript) {
                            model.copy(transcript.text)
                            closeMenu()
                        }
                    }
                }
            }
            .padding(5)

            Divider().overlay(.white.opacity(0.2))

            HStack(spacing: 0) {
                FooterButton(
                    title: model.isPaused ? "Resume" : "Pause",
                    symbol: model.isPaused ? "play.fill" : "pause.fill"
                ) {
                    model.isPaused.toggle()
                }
                FooterButton(title: "Settings", symbol: "gearshape.fill") {
                    closeMenu()
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                FooterButton(title: "Quit", symbol: "power") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(5)
        }
        .frame(width: 300)
        .foregroundStyle(.white)
        .background(Brand.gradient)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if model.isListening {
                    RecordingDot()
                } else {
                    Circle()
                        .fill(model.isReady ? .red : .yellow)
                        .frame(width: 10, height: 10)
                        .frame(width: 22, height: 22)
                }
                Waveform(levels: model.isListening ? model.levels : [0.95, 0.7, 0.45, 0.25, 0.1])
                Spacer(minLength: 0)
            }
            .padding(.leading, 9)
            .padding(.trailing, 16)
            .frame(height: 40)
            .glassEffect(.regular, in: .capsule)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(model.statusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func closeMenu() {
        NSApp.keyWindow?.close()
    }
}

private struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.white.opacity(0.6))
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(.rect)
            .background(isHovered && isEnabled ? .white.opacity(0.18) : .clear, in: .rect(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct RecentRow: View {
    let transcript: Transcript
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(transcript.text)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background(isHovered ? .white.opacity(0.18) : .clear, in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Click to copy")
    }

    private var caption: String {
        let time = transcript.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        guard let app = transcript.appName else { return time }
        return "\(app) · \(time)"
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(.rect)
                .background(isHovered ? .white.opacity(0.18) : .clear, in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
