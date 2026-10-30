import AppKit
import AVFoundation
import Observation
import OSLog

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

private let log = Logger(subsystem: "com.chrisyeh.Blabberflow", category: "Dictation")

/// Runs the dictation loop: hotkey → record → transcribe → insert, and drives the pill.
@Observable
final class AppModel {
    let preferences = Preferences()

    var pillState = PillState.idle
    /// Recent microphone levels, newest first, each 0…1.
    var levels: [Float] = Array(repeating: 0, count: 5)
    var recent: [Transcript] = []
    var hasAccessibility = AXIsProcessTrusted()
    var hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    var speechStatus: SpeechStatus = .preparing
    /// True in press-to-start mode while recording; the pill shows a timer and stop/cancel buttons.
    private(set) var isHandsFree = false
    private(set) var listeningSince = Date.now
    var isPaused = false {
        didSet {
            updateHotkeyEnabled()
            if isPaused { cancelDictation() }
        }
    }
    /// Set while a shortcut field in Settings is recording, so pressing the current shortcut doesn't dictate.
    var isRecordingShortcut = false {
        didSet { updateHotkeyEnabled() }
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
        return "\(shortcutHint) · on-device"
    }

    /// "Hold Right ⌥ to dictate" or "Press Right ⌥ to start and stop".
    var shortcutHint: String {
        let key = preferences.dictationShortcut.display
        switch preferences.activationMode {
        case .hold: return "Hold \(key) to dictate"
        case .toggle: return "Press \(key) to start and stop"
        }
    }

    private enum Phase { case idle, pending, listening, processing }

    /// Holds shorter than this are treated as ordinary key presses.
    private let holdThreshold = Duration.milliseconds(250)
    /// In press-to-start mode, a modifier key held longer than this isn't a tap.
    private let tapLimit = Duration.milliseconds(500)
    /// The waveform redraws at most this often.
    private let levelInterval = Duration.milliseconds(33)
    /// Below this RMS for a whole recording, the mic delivered silence (muted, lid closed, wrong input).
    private let silenceLevel: Float = 0.0005

    @ObservationIgnored private var phase = Phase.idle
    @ObservationIgnored private let hotkey = HotkeyMonitor()
    @ObservationIgnored private let engine = DictationEngine()
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private lazy var pill = PillPanel(model: self)
    @ObservationIgnored private var startError: Error?
    @ObservationIgnored private var targetAppName: String?
    @ObservationIgnored private var microphoneName = "the microphone"
    @ObservationIgnored private var peakLevel: Float = 0
    @ObservationIgnored private var pressedAt = ContinuousClock.now
    @ObservationIgnored private var tapInterrupted = false
    /// The app to give focus back to when Paste Last is chosen from the menu bar panel.
    @ObservationIgnored private var lastOtherApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var lastLevelUpdate = ContinuousClock.now
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func start() {
        hotkey.onEvent = { [weak self] in self?.handle($0) }
        engine.onLevel = { [weak self] in self?.push(level: $0) }
        preferences.onChange = { [weak self] in self?.applyPreferences() }
        applyPreferences()
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
            hasMicrophone = await AVCaptureDevice.requestAccess(for: .audio)
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
        hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// The pill's stop button in press-to-start mode.
    func stopFromPill() {
        guard phase == .listening else { return }
        endDictation()
    }

    /// The pill's cancel button.
    func cancelFromPill() {
        cancelDictation()
    }

    // MARK: Setup

    private func applyPreferences() {
        hotkey.dictationShortcut = preferences.dictationShortcut
        hotkey.pasteLastShortcut = preferences.pasteLastShortcut
    }

    private func updateHotkeyEnabled() {
        hotkey.isEnabled = !isPaused && !isRecordingShortcut
    }

    private func startHotkeyWhenTrusted() async {
        while !hotkey.start() {
            hasAccessibility = false
            try? await Task.sleep(for: .seconds(1))
        }
        hasAccessibility = true
        log.info("Hotkey monitor running")
    }

    private func prepareSpeech() async {
        speechStatus = .preparing
        do {
            try await engine.prepare()
            speechStatus = .ready
            log.info("Speech model ready")
        } catch {
            speechStatus = .failed(error.localizedDescription)
            log.error("Speech model failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Hotkey

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .escape:
            cancelDictation()
        case .pasteLast:
            pasteLast()
        case .pressed, .released, .keyWhileHeld:
            switch preferences.activationMode {
            case .hold: handleHold(event)
            case .toggle: handleToggle(event)
            }
        }
    }

    private func handleHold(_ event: HotkeyEvent) {
        switch event {
        case .pressed: beginHold()
        case .released: endDictation()
        case .keyWhileHeld: if phase == .pending { cancelDictation() }
        default: break
        }
    }

    /// A modifier key toggles on a clean tap, so ⌥-shortcuts keep working; a key combo toggles on press.
    private func handleToggle(_ event: HotkeyEvent) {
        let isModifierKey = preferences.dictationShortcut.isModifierKey
        switch event {
        case .pressed:
            if phase == .listening {
                endDictation()
            } else if phase == .idle {
                pressedAt = .now
                tapInterrupted = false
                if !isModifierKey { beginHandsFree() }
            }
        case .released:
            guard isModifierKey, phase == .idle, !tapInterrupted, ContinuousClock.now - pressedAt < tapLimit else { return }
            beginHandsFree()
        case .keyWhileHeld:
            tapInterrupted = true
        default:
            break
        }
    }

    /// Starts recording on key down so the first word isn't clipped; the pill appears once it's clearly a hold.
    private func beginHold() {
        guard phase == .idle else { return }
        phase = .pending
        isHandsFree = false
        startRecording()

        holdTask = Task {
            try? await Task.sleep(for: holdThreshold)
            guard !Task.isCancelled, phase == .pending else { return }
            if let startError {
                engine.cancel()
                phase = .idle
                flash(.error(startError.localizedDescription), for: .seconds(3))
                return
            }
            showListening()
        }
    }

    private func beginHandsFree() {
        guard phase == .idle else { return }
        startRecording()
        if let startError {
            flash(.error(startError.localizedDescription), for: .seconds(3))
            return
        }
        isHandsFree = true
        showListening()
    }

    private func startRecording() {
        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        let device = AudioDevices.device(uid: preferences.microphoneUID)
        microphoneName = device?.name ?? "the microphone"
        peakLevel = 0
        startError = nil
        do {
            try engine.start(device: device?.id)
            log.info("Recording from \(self.microphoneName, privacy: .public)")
        } catch {
            startError = error
            log.error("Couldn't start recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func showListening() {
        phase = .listening
        hotkey.capturesEscape = true
        dismissTask?.cancel()
        levels = Array(repeating: 0, count: levels.count)
        listeningSince = .now
        pill.show()
        pill.acceptsClicks = isHandsFree
        pillState = .listening
        announce("Listening")
    }

    private func endDictation() {
        switch phase {
        case .pending:
            cancelDictation()
        case .listening:
            phase = .processing
            pill.acceptsClicks = false
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
            isHandsFree = false
            hotkey.capturesEscape = false
            log.info("Transcribed \(text.count) characters, peak level \(self.peakLevel)")
            guard !text.isEmpty else {
                if peakLevel < silenceLevel {
                    flash(.error("No audio from \(microphoneName)"), for: .seconds(4))
                } else {
                    flash(.error("Didn't catch that"), for: .seconds(2))
                }
                return
            }
            recent.insert(Transcript(text: text, appName: targetAppName, date: .now), at: 0)
            recent = Array(recent.prefix(50))
            await insert(text)
        } catch {
            phase = .idle
            isHandsFree = false
            hotkey.capturesEscape = false
            log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            flash(.error("Couldn't transcribe"), for: .seconds(3))
        }
    }

    private func cancelDictation() {
        holdTask?.cancel()
        engine.cancel()
        hotkey.capturesEscape = false
        pill.acceptsClicks = false
        if phase == .listening || phase == .processing { pillState = .idle }
        phase = .idle
        isHandsFree = false
    }

    private func insert(_ text: String) async {
        let outcome = await inserter.insert(text)
        log.info("Insert outcome: \(String(describing: outcome), privacy: .public)")
        switch outcome {
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
        peakLevel = max(peakLevel, rms)
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
