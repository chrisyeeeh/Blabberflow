import SwiftUI

/// One glass capsule whose content and size change with the state, so it morphs like the Dynamic Island.
struct PillView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            if showsPreview {
                LivePreview(text: model.liveText)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
            content
                .id(contentKey)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                .frame(height: model.pillState == .idle ? 7 : 40)
                .glassEffect(.regular, in: .capsule)
                .opacity(model.isPaused && model.pillState == .idle ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.pillState)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showsPreview)
    }

    private var showsPreview: Bool {
        model.preferences.showsLivePreview && model.pillState == .listening && !model.liveText.isEmpty
    }

    /// Changes only when the layout changes, so the waveform doesn't re-transition on every level update.
    private var contentKey: String {
        switch model.pillState {
        case .idle: "idle"
        case .listening: model.isHandsFree ? "handsFree" : "listening"
        case .processing: "processing"
        case .inserted: "inserted"
        case .copied: "copied"
        case .error: "error"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.pillState {
        case .idle:
            Color.clear
                .frame(width: 40)
        case .listening where model.isHandsFree:
            HandsFreeControls(model: model)
        case .listening:
            HStack(spacing: 12) {
                RecordingDot()
                Waveform(levels: model.levels)
                if let style = model.activeStyleName {
                    StyleChip(name: style)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.activeStyleName.map { "Listening, \($0) style" } ?? "Listening")
        case .processing:
            ShimmerLine()
                .padding(.horizontal, 18)
                .accessibilityLabel("Processing")
        case .inserted(let words):
            StatusLabel(
                text: "\(words) \(words == 1 ? "word" : "words")",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
            .accessibilityLabel("Inserted \(words) words")
        case .copied:
            StatusLabel(text: "Copied — ⌘V to paste", symbol: "doc.on.clipboard", tint: .yellow)
        case .error(let reason):
            StatusLabel(text: reason, symbol: "exclamationmark.triangle.fill", tint: .yellow)
        }
    }
}

/// Press-to-start mode: elapsed time, waveform, cancel and stop. Clicking the pill body does nothing,
/// so recording can't be stopped by accident.
private struct HandsFreeControls: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: model.listeningSince, by: 1)) { context in
                Text(Duration.seconds(context.date.timeIntervalSince(model.listeningSince)), format: .time(pattern: .minuteSecond))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Waveform(levels: model.levels)
            Button(action: model.cancelFromPill) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.18), in: .circle)
            }
            .accessibilityLabel("Cancel")
            Button(action: model.stopFromPill) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 9, height: 9)
                    .frame(width: 28, height: 28)
                    .background(.red, in: .circle)
            }
            .accessibilityLabel("Stop and insert")
        }
        .buttonStyle(.plain)
        .padding(.leading, 14)
        .padding(.trailing, 6)
    }
}

/// Which style will be applied, after a hairline divider.
private struct StyleChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(.secondary.opacity(0.5))
                .frame(width: 0.5, height: 16)
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

/// The words so far, above the pill. Shows the end of long dictations, where the newest words are.
private struct LivePreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: 460)
            .fixedSize(horizontal: false, vertical: true)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.15), value: text)
            .accessibilityHidden(true) // VoiceOver hears "Listening"; announcing every word would be noise.
    }
}

/// 22 pt red circle with a microphone.
struct RecordingDot: View {
    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(.red, in: .circle)
    }
}

/// Nine bars, 3 pt wide with 3 pt gaps, 6–22 pt tall, mirrored so the newest level sits in the middle.
struct Waveform: View {
    let levels: [Float]

    var body: some View {
        let mirrored = levels.reversed() + levels.dropFirst()
        HStack(spacing: 3) {
            ForEach(Array(mirrored.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: 6 + 16 * CGFloat(level))
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

/// The bars collapse into a 120 × 4 pt line with a highlight sweeping across it.
private struct ShimmerLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let width: CGFloat = 120
    private let period = 1.2

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            Capsule()
                .fill(.primary.opacity(0.25))
                .overlay {
                    LinearGradient(colors: [.clear, .primary.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                        .offset(x: reduceMotion ? 0 : (progress * 2 - 1) * width)
                }
                .clipShape(.capsule)
                .frame(width: width, height: 4)
        }
    }
}

private struct StatusLabel: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(symbol.hasSuffix(".fill") ? .white : tint, tint)
                .font(.system(size: 15))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
    }
}
