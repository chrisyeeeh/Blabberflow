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
    /// The transcript so far while recording, including words not yet final.
    var onPartial: ((String) -> Void)?

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

    /// Picks the transcriber locale and downloads its model if needed. Call at launch, and again to retry.
    /// - Parameter onDownload: Called on the main actor with the language name and 0…1 while downloading.
    func prepare(onDownload: @escaping @MainActor @Sendable (String, Double) -> Void) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw EngineError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let language = Locale.current.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "")
                ?? locale.identifier
            onDownload(language, 0)
            let observation = request.progress.observe(\.fractionCompleted) { progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in onDownload(language, fraction) }
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.locale = locale
    }

    /// Starts recording at once; the analyzer catches up from the buffered audio.
    /// - Parameters:
    ///   - device: The microphone to use; `nil` uses the system default.
    ///   - vocabulary: Words, names and acronyms the recogniser should favour.
    func start(device: AudioDeviceID?, vocabulary: [String]) throws {
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
            for try await result in transcriber.results {
                let segment = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                if result.isFinal, !segment.isEmpty {
                    text += text.isEmpty ? segment : " " + segment
                }
                // Finalised text so far plus the words still being worked out.
                let volatile = result.isFinal || segment.isEmpty ? "" : segment
                onPartial?([text, volatile].filter { !$0.isEmpty }.joined(separator: " "))
            }
            return text
        }
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        let started = Task {
            if !vocabulary.isEmpty { try await analyzer.setContext(context) }
            try await analyzer.start(inputSequence: stream)
        }
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
