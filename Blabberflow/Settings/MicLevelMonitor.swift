import AVFAudio
import Observation
import SwiftUI

/// Runs the chosen microphone only while "Test" is on in Settings, so the mic isn't live whenever Settings is open.
@Observable
final class MicLevelMonitor {
    /// 0…1, mapped from roughly -50 dB…-10 dB like the pill's waveform.
    private(set) var level: Float = 0
    private(set) var isRunning = false

    @ObservationIgnored private let capture = AudioCapture()

    func start(deviceUID: String?) {
        guard !isRunning, let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else { return }
        do {
            try capture.start(
                device: AudioDevices.device(uid: deviceUID)?.id,
                outputFormat: format,
                onBuffer: { _ in },
                onLevel: { [weak self] rms in
                    Task { @MainActor in self?.update(rms) }
                }
            )
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func restart(deviceUID: String?) {
        stop()
        start(deviceUID: deviceUID)
    }

    func stop() {
        guard isRunning else { return }
        capture.stop()
        isRunning = false
        level = 0
    }

    private func update(_ rms: Float) {
        guard isRunning else { return }
        let decibels = 20 * log10(max(rms, 0.000_01))
        level = min(1, max(0, (decibels + 50) / 40))
    }
}

/// Eight segments that light green with the input level.
struct LevelMeter: View {
    let level: Float
    private let segments = 8

    var body: some View {
        let lit = Int((level * Float(segments)).rounded())
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < lit ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 14, height: 8)
            }
        }
        .animation(.easeOut(duration: 0.08), value: lit)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
