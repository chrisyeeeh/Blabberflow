import AVFoundation
import Speech

/// Records from the microphone and transcribes on-device with SpeechAnalyzer.
final class DictationEngine {
    enum EngineError: LocalizedError {
        case unsupportedLocale
        case notReady
        case microphoneDenied

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale: "Language not supported"
            case .notReady: "Speech model not ready"
            case .microphoneDenied: "Mic unavailable"
            }
        }
    }

    /// Microphone level (RMS, 0…1), delivered on the main actor.
    var onLevel: ((Float) -> Void)?

    private let capture = AudioCapture()
    private var locale: Locale?
    private var analyzerFormat: AVAudioFormat?
    private var session: Session?

    private struct Session {
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        let started: Task<Void, Error>
        let transcript: Task<String, Error>
    }

    /// Picks the transcriber locale and downloads its model if needed. Call once at launch.
    func prepare() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw EngineError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.locale = locale
    }

    /// Starts recording at once; the analyzer catches up from the buffered audio.
    /// - Parameter device: The microphone to use; `nil` uses the system default.
    func start(device: AudioDeviceID?) throws {
        guard session == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw EngineError.microphoneDenied }
        guard let locale, let analyzerFormat else { throw EngineError.notReady }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()

        try capture.start(
            device: device,
            outputFormat: analyzerFormat,
            onBuffer: { buffer in input.yield(AnalyzerInput(buffer: buffer)) },
            onLevel: { [weak self] level in
                Task { @MainActor in self?.onLevel?(level) }
            }
        )

        let transcript = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                let segment = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                guard !segment.isEmpty else { continue }
                text += text.isEmpty ? segment : " " + segment
            }
            return text
        }
        let started = Task { try await analyzer.start(inputSequence: stream) }
        session = Session(analyzer: analyzer, input: input, started: started, transcript: transcript)
    }

    /// Stops recording and returns the final transcript.
    func finish() async throws -> String {
        guard let session else { return "" }
        self.session = nil
        capture.stop()
        session.input.finish()
        try await session.started.value
        try await session.analyzer.finalizeAndFinishThroughEndOfInput()
        return try await session.transcript.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops recording and throws the audio away.
    func cancel() {
        guard let session else { return }
        self.session = nil
        capture.stop()
        session.input.finish()
        Task {
            await session.analyzer.cancelAndFinishNow()
            session.transcript.cancel()
        }
    }
}
