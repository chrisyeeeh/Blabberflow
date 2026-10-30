import AppKit
import AVFAudio
import Observation

enum PillState: Equatable {
    /// The 40 × 7 pt sliver that is always there.
    case idle
    case listening
    case processing
    case inserted(words: Int)
    /// No editable field; the text is on the clipboard.
    case copied
    case error(String)
}

enum SpeechStatus: Equatable {
    case preparing
    case ready
    case failed(String)
}

struct Transcript: Identifiable {
    let id = UUID()
    let text: String
    let appName: String?
    let date: Date
}

/// Runs the hold-to-talk loop: hotkey → record → transcribe → insert, and drives the pill.
@Observable
final class AppModel {
    var pillState = PillState.idle
    /// Recent microphone levels, newest first, each 0…1.
    var levels: [Float] = Array(repeating: 0, count: 5)
    var recent: [Transcript] = []
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

    var isReady: Bool {
        hasAccessibility && hasMicrophone && speechStatus == .ready && !isPaused
    }

    var statusTitle: String {
        if !hasAccessibility { return "Needs Accessibility access" }
        if !hasMicrophone { return "Needs microphone access" }
        switch speechStatus {
        case .preparing: return "Getting the speech model ready…"
        case .failed(let reason): return reason
        case .ready: return isPaused ? "Blabberflow is paused" : "Blabberflow is ready"
        }
    }

    var statusDetail: String {
        if !hasAccessibility || !hasMicrophone { return "Open Settings to allow it" }
        return "Hold right ⌥ to dictate · on-device"
    }

    private enum Phase { case idle, pending, listening, processing }

    /// Holds shorter than this are treated as ordinary Option presses.
    private let holdThreshold = Duration.milliseconds(250)
    /// The waveform redraws at most this often.
    private let levelInterval = Duration.milliseconds(33)

    @ObservationIgnored private var phase = Phase.idle
    @ObservationIgnored private let hotkey = HotkeyMonitor()
    @ObservationIgnored private let engine = DictationEngine()
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private lazy var pill = PillPanel(model: self)
    @ObservationIgnored private var startError: Error?
    @ObservationIgnored private var targetAppName: String?
    /// The app to give focus back to when Paste Last is chosen from the menu bar panel.
    @ObservationIgnored private var lastOtherApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var lastLevelUpdate = ContinuousClock.now
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func start() {
        hotkey.onEvent = { [weak self] in self?.handle($0) }
        engine.onLevel = { [weak self] in self?.push(level: $0) }
        pill.show()

        lastOtherApp = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app, app != .current else { return }
                self?.lastOtherApp = app
            }
        }

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
        guard let text = recent.first?.text else { return }
        if NSApp.isActive { lastOtherApp?.activate() }
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
        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        // Start recording on key down so the first word isn't clipped.
        startError = nil
        do { try engine.start() } catch { startError = error }

        holdTask = Task {
            try? await Task.sleep(for: holdThreshold)
            guard !Task.isCancelled, phase == .pending else { return }
            if let startError {
                phase = .idle
                flash(.error(startError.localizedDescription), for: .seconds(3))
                return
            }
            phase = .listening
            hotkey.capturesEscape = true
            dismissTask?.cancel()
            levels = Array(repeating: 0, count: levels.count)
            pill.show()
            pillState = .listening
            announce("Listening")
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
                pillState = .idle
                return
            }
            recent.insert(Transcript(text: text, appName: targetAppName, date: .now), at: 0)
            recent = Array(recent.prefix(10))
            await insert(text)
        } catch {
            phase = .idle
            hotkey.capturesEscape = false
            flash(.error("Couldn't transcribe"), for: .seconds(3))
        }
    }

    private func cancelDictation() {
        holdTask?.cancel()
        engine.cancel()
        hotkey.capturesEscape = false
        if phase == .listening || phase == .processing { pillState = .idle }
        phase = .idle
    }

    private func insert(_ text: String) async {
        switch await inserter.insert(text) {
        case .inserted, .pasted:
            let words = text.split(whereSeparator: \.isWhitespace).count
            flash(.inserted(words: words), for: .milliseconds(600))
            announce("Inserted \(words) \(words == 1 ? "word" : "words")")
        case .copied:
            flash(.copied, for: .seconds(3))
            announce("Copied. Press Command V to paste")
        case .secureField:
            flash(.error("Secure field"), for: .seconds(3))
        }
    }

    // MARK: Pill

    private func push(level rms: Float) {
        guard phase == .listening || phase == .pending else { return }
        let now = ContinuousClock.now
        guard now - lastLevelUpdate >= levelInterval else { return }
        lastLevelUpdate = now
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
            pillState = .idle
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}
