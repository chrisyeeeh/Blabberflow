import SwiftUI

struct PillView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            if model.pillState != .hidden {
                content
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.scale(scale: 0.3, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.pillState)
    }

    @ViewBuilder private var content: some View {
        switch model.pillState {
        case .hidden:
            EmptyView()
        case .listening:
            HStack(spacing: 10) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Waveform(levels: model.levels)
            }
            .frame(width: 152)
            .accessibilityLabel("Listening")
        case .processing:
            ProcessingBars()
                .frame(width: 152)
                .accessibilityLabel("Processing")
        case .inserted:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityLabel("Inserted")
        case .message(let text, let isError):
            HStack(spacing: 6) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "doc.on.clipboard")
                    .foregroundStyle(isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Text(text)
            }
            .font(.system(size: 12, weight: .medium))
            .fixedSize()
        }
    }
}

/// Nine bars mirrored around the centre; the newest level sits in the middle.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        let mirrored = levels.reversed() + levels.dropFirst()
        HStack(spacing: 3) {
            ForEach(Array(mirrored.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: 4 + 18 * CGFloat(level))
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

/// The waveform settles into a travelling shimmer while the transcript is finalised.
private struct ProcessingBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<9, id: \.self) { index in
                    let phase = (sin(time * 6 - Double(index) * 0.6) + 1) / 2
                    Capsule()
                        .fill(.primary)
                        .frame(width: 3, height: 4 + 4 * phase)
                        .opacity(0.3 + 0.5 * phase)
                }
            }
            .frame(height: 24)
        }
    }
}
