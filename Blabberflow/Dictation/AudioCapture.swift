import AVFAudio

/// Microphone capture. The tap runs on a real-time audio thread, so this type is not main-actor isolated.
nonisolated final class AudioCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInputDevice
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone"
            case .unsupportedFormat: "Mic unavailable"
            }
        }
    }

    private let engine = AVAudioEngine()

    /// - Parameter device: The input to record from; `nil` uses the system default.
    func start(
        device: AudioDeviceID?,
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        let input = engine.inputNode
        // The engine keeps the last device, so always set one: the chosen input or the current default.
        if let device = device ?? AudioDevices.defaultInputID() {
            try input.auAudioUnit.setDeviceID(device)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noInputDevice }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { throw CaptureError.unsupportedFormat }
        // Mix every channel into mono, so a mic on input 2 of an interface isn't dropped.
        converter.downmix = true

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            onLevel(Self.rms(of: buffer))
            if let converted = Self.convert(buffer, with: converter, to: outputFormat) {
                onBuffer(converted)
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// The loudest channel's RMS, so a quiet or unused channel doesn't hide speech on another.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        let stride = buffer.stride
        var loudest: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            // Interleaved audio keeps every channel in the first pointer, offset by the channel index.
            let samples = buffer.format.isInterleaved ? channels[0] + channel : channels[channel]
            var sum: Float = 0
            for frame in 0..<count {
                let sample = samples[frame * stride]
                sum += sample * sample
            }
            loudest = max(loudest, (sum / Float(count)).squareRoot())
        }
        return loudest
    }
}
