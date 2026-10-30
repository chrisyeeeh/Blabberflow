import AppKit
import AVFAudio
import Observation

enum PillState: Equatable {
    case hidden
    case listening
    case processing
    case inserted
    case message(String, isError: Bool)
}

enum SpeechStatus: Equatable {
    case preparing
    case ready
    case failed(String)
}

/// Runs the hold-to-talk loop: hotkey → record → transcribe → insert, and drives the pill.
@Observable
final class AppModel {
    var pillState: PillState = .hidden
    /// Recent microphone levels, newest first, each 0…1.
    var levels: [Float] = Array(repeating: 0, count: 5)
    var recent: [String] = []
    var hasAccessibility = AXIsProcessTrusted()
    var hasMicrophone = AVAudioApplication.shared.recordPermission == .granted
    var speechStatus: SpeechStatus = .preparing
    var isPaused = false {
        didSet {
            hotkey.isEnabled = !isPaused
            if isPaused { cancelDictation() }
        }
    }

    var isListening: Bool { phase == .listening }

    var statusLine: String {
        if !hasAccessibility { return "Needs Accessibility access" }
        if !hasMicrophone { return "Needs microphone access" }
        switch speechStatus {
        case .preparing: return "Getting the speech model ready…"
        case .failed(let reason): return reason
        case .ready: return isPaused ? "Paused" : "Ready — hold right ⌥ to dictate"
        }
    }

    private enum Phase { case idle, pending, listening, processing }

    /// Holds shorter than this are treated as ordinary Option presses.
    private let holdThreshold = Duration.milliseconds(250)

    @ObservationIgnored private var phase = Phase.idle
    @ObservationIgnored private let hotkey = HotkeyMonitor()
    @ObservationIgnored private let engine = DictationEngine()
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private lazy var pill = PillPanel(model: self)
    @ObservationIgnored private var startError: Error?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func start() {
        hotkey.onEvent = { [weak self] in self?.handle($0) }
        engine.onLevel = { [weak self] in self?.push(level: $0) }
        pill.show()

        if !hasAccessibility {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        Task { await startHotkeyWhenTrusted() }
        Task {
            hasMicrophone = await AVAudioApplication.requestRecordPermission()
            await prepareSpeech()
        }
    }

    func pasteLast() {
        guard let text = recent.first else { return }
        Task {
            // Let the menu close and focus return to the previous app.
            try? await Task.sleep(for: .milliseconds(150))
            await insert(text)
        }
    }

    func copy(_ text: String) {
        inserter.copyToClipboard(text)
    }

    func refreshPermissions() {
        hasAccessibility = AXIsProcessTrusted()
        hasMicrophone = AVAudioApplication.shared.recordPermission == .granted
    }

    // MARK: Setup

    private func startHotkeyWhenTrusted() async {
        while !hotkey.start() {
            hasAccessibility = false
            try? await Task.sleep(for: .seconds(1))
        }
        hasAccessibility = true
    }

    private func prepareSpeech() async {
        speechStatus = .preparing
        do {
            try await engine.prepare()
            speechStatus = .ready
        } catch {
            speechStatus = .failed(error.localizedDescription)
        }
    }

    // MARK: Hotkey

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .pressed: beginDictation()
        case .released: endDictation()
        case .keyWhileHeld: if phase == .pending { cancelDictation() }
        case .escape: cancelDictation()
        case .pasteLast: pasteLast()
        }
    }

    private func beginDictation() {
        guard phase == .idle else { return }
        phase = .pending
        // Start recording on key down so the first word isn't clipped.
        startError = nil
        do { try engine.start() } catch { startError = error }

        holdTask = Task {
            try? await Task.sleep(for: holdThreshold)
            guard !Task.isCancelled, phase == .pending else { return }
            if let startError {
                phase = .idle
                flash(.message(startError.localizedDescription, isError: true), for: .seconds(3))
                return
            }
            phase = .listening
            hotkey.capturesEscape = true
            dismissTask?.cancel()
            levels = Array(repeating: 0, count: levels.count)
            pill.show()
            pillState = .listening
        }
    }

    private func endDictation() {
        switch phase {
        case .pending:
            cancelDictation()
        case .listening:
            phase = .processing
            pillState = .processing
            Task { await finishDictation() }
        case .idle, .processing:
            break
        }
    }

    private func finishDictation() async {
        do {
            let text = try await engine.finish()
            guard phase == .processing else { return } // Cancelled with Escape.
            phase = .idle
            hotkey.capturesEscape = false
            guard !text.isEmpty else {
                pillState = .hidden
                return
            }
            recent.insert(text, at: 0)
            recent = Array(recent.prefix(10))
            await insert(text)
        } catch {
            phase = .idle
            hotkey.capturesEscape = false
            flash(.message("Couldn't transcribe", isError: true), for: .seconds(3))
        }
    }

    private func cancelDictation() {
        holdTask?.cancel()
        engine.cancel()
        hotkey.capturesEscape = false
        if phase == .listening || phase == .processing { pillState = .hidden }
        phase = .idle
    }

    private func insert(_ text: String) async {
        switch await inserter.insert(text) {
        case .inserted, .pasted:
            flash(.inserted, for: .milliseconds(600))
        case .copied:
            flash(.message("Copied — ⌘V to paste", isError: false), for: .seconds(3))
        case .secureField:
            flash(.message("Secure field", isError: true), for: .seconds(3))
        }
    }

    // MARK: Pill

    private func push(level rms: Float) {
        guard phase == .listening || phase == .pending else { return }
        // Map roughly -50 dB…-10 dB onto 0…1.
        let decibels = 20 * log10(max(rms, 0.000_01))
        let level = min(1, max(0, (decibels + 50) / 40))
        levels = [level] + levels.dropLast()
    }

    private func flash(_ state: PillState, for duration: Duration) {
        dismissTask?.cancel()
        pill.show()
        pillState = state
        dismissTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, pillState == state else { return }
            pillState = .hidden
        }
    }
}
