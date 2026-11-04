import AVFAudio
import AudioToolbox

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

    /// A fresh engine per recording. A reused engine keeps its audio unit initialised after `stop()`,
    /// so a later device change can be ignored (it records from the old mic) or hang while the unit reconfigures.
    private var engine: AVAudioEngine?

    /// - Parameter device: The input to record from; `nil` uses the system default.
    func start(
        device: AudioDeviceID?,
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Always set a device, before anything reads the node's format: the chosen input or the current default.
        if let device = device ?? AudioDevices.defaultInputID() {
            try Self.setDevice(device, on: input)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noInputDevice }
        guard let converter = Converter(from: inputFormat, to: outputFormat) else { throw CaptureError.unsupportedFormat }

        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            onLevel(Self.rms(of: buffer))
            if let converted = converter.convert(buffer) {
                onBuffer(converted)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Points the input node's audio unit at `device` through Core Audio, and checks it took.
    private static func setDevice(_ device: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else {
            try input.auAudioUnit.setDeviceID(device)
            return
        }
        var id = device
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw CaptureError.noInputDevice }
    }

    /// Converts tap buffers to the output format, rebuilding itself if the device's format changes mid-recording.
    private final class Converter: @unchecked Sendable {
        private var converter: AVAudioConverter
        private let outputFormat: AVAudioFormat

        init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
            guard let converter = Self.make(from: inputFormat, to: outputFormat) else { return nil }
            self.converter = converter
            self.outputFormat = outputFormat
        }

        func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            if buffer.format != converter.inputFormat {
                guard let rebuilt = Self.make(from: buffer.format, to: outputFormat) else { return nil }
                converter = rebuilt
            }
            return AudioCapture.convert(buffer, with: converter, to: outputFormat)
        }

        private static func make(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) -> AVAudioConverter? {
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            // Mix every channel into mono, so a mic on input 2 of an interface isn't dropped.
            converter?.downmix = true
            return converter
        }
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
