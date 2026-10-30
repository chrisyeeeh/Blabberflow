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
    /// Fetching the language's model from Apple; `fraction` is 0…1.
    case downloading(language: String, fraction: Double)
    case ready
    case failed(String)

    /// One line shared by Settings and the menu header, e.g. "Downloading English speech model… 42%".
    var summary: String {
        switch self {
        case .preparing: "Getting the speech model ready…"
        case .downloading(let language, let fraction):
            "Downloading \(language) speech model… \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .ready: "Ready"
        case .failed(let reason): "Speech model unavailable: \(reason)"
        }
    }
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
    let history = HistoryStore()

    var pillState = PillState.idle
    /// The words recognised so far, shown above the pill when live preview is on.
    private(set) var liveText = ""
    /// The style this dictation will be written in, shown as a chip on the pill.
    private(set) var activeStyleName: String?
    var appleIntelligence = AppleIntelligenceStatus.current
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

    /// Observable (unlike `phase`), so the menu bar icon can follow it.
    var isListening: Bool { pillState == .listening }

    var isReady: Bool {
        hasAccessibility && hasMicrophone && speechStatus == .ready && !isPaused
    }

    var statusTitle: String {
        if !hasAccessibility { return "Needs Accessibility access" }
        if !hasMicrophone { return "Needs microphone access" }
        switch speechStatus {
        case .ready: return isPaused ? "BlabberFlow is paused" : "BlabberFlow is ready"
        case .preparing, .downloading, .failed: return speechStatus.summary
        }
    }

    var statusDetail: String {
        if !hasAccessibility || !hasMicrophone { return "Open Settings to allow it" }
        switch speechStatus {
        case .failed: return "Choose Retry below, or in Settings › General"
        case .preparing, .downloading: return "One time, shared with other apps"
        case .ready: return "\(shortcutHint) · on-device"
        }
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
    @ObservationIgnored private let rewriter = StyleRewriter()
    @ObservationIgnored private var sessionStyle = Style.builtIn[0]
    /// The style of the shortcut that was just pressed; `nil` is the main shortcut.
    @ObservationIgnored private var pressedStyleID: UUID?
    @ObservationIgnored private var releasedAt = Date.now
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
        engine.onPartial = { [weak self] text in
            guard let self, self.phase == .listening || self.phase == .pending else { return }
            self.liveText = text
        }
        preferences.onChange = { [weak self] in self?.applyPreferences() }
        applyPreferences()
        pill.show()

        history.prune(olderThan: preferences.historyRetentionDays)
        if preferences.keepsHistory {
            recent = history.latest(10).map { Transcript(text: $0.text, appName: $0.appName, date: $0.date) }
        }

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
        appleIntelligence = .current
    }

    /// Deletes saved transcripts; Insights keep their counts.
    func clearHistory() {
        history.clearHistory()
        recent.removeAll()
    }

    /// Deletes one saved transcript (and its menu entry); Insights keep their counts.
    func deleteHistory(_ entry: HistoryEntry) {
        recent.removeAll { $0.text == entry.text && $0.date == entry.date }
        history.delete(entry)
    }

    /// Types text into the app that was in front before BlabberFlow, e.g. a rewrite from History.
    func pasteIntoLastApp(_ text: String) {
        lastOtherApp?.activate()
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await insert(text)
        }
    }

    func resetInsights() {
        history.resetInsights()
    }

    /// Rewrites sample text in a style, for "Try it" in Settings.
    func preview(_ text: String, in style: Style) async throws -> String {
        let corrected = Vocabulary.apply(preferences.dictionary, to: text)
        guard !style.isLiteral else { return corrected }
        guard AppleIntelligenceStatus.current == .ready else { throw PreviewError.appleIntelligenceUnavailable }
        // Same path as a real dictation, so "Try it" and "Rewrite as" show what would actually be inserted.
        let rewritten = await rewriter.styledText(corrected, style: style, dictionary: preferences.dictionary)
        return Vocabulary.apply(preferences.dictionary, to: rewritten)
    }

    enum PreviewError: LocalizedError {
        case appleIntelligenceUnavailable
        var errorDescription: String? { "Apple Intelligence isn't ready" }
    }

    /// "Start Dictation" in the menu: records hands-free until the pill's stop button or the shortcut.
    func startDictationFromMenu() {
        if NSApp.isActive { lastOtherApp?.activate() }
        Task {
            // Let the menu close and focus return to the app being dictated into.
            try? await Task.sleep(for: .milliseconds(150))
            beginHandsFree()
        }
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
        var bindings = [DictationBinding(shortcut: preferences.dictationShortcut)]
        for style in preferences.styles {
            guard let shortcut = style.shortcut, !bindings.contains(where: { $0.shortcut == shortcut }) else { continue }
            bindings.append(DictationBinding(shortcut: shortcut, style: style.id))
        }
        if hotkey.bindings != bindings { hotkey.bindings = bindings }
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

    /// Tries the speech model download again after a failure, without relaunching.
    func retrySpeech() {
        guard case .failed = speechStatus else { return }
        Task { await prepareSpeech() }
    }

    private func prepareSpeech() async {
        speechStatus = .preparing
        do {
            try await engine.prepare { [weak self] language, fraction in
                self?.speechStatus = .downloading(language: language, fraction: fraction)
            }
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
            if case .pressed(let style) = event, phase == .idle { pressedStyleID = style }
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
        let shortcut = pressedStyleID.flatMap { preferences.style(id: $0).shortcut } ?? preferences.dictationShortcut
        let isModifierKey = shortcut.isModifierKey
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
        liveText = ""
        sessionStyle = preferences.style(id: pressedStyleID)
        pressedStyleID = nil
        rewriter.prepare(style: sessionStyle, dictionary: preferences.dictionary)
        do {
            try engine.start(device: device?.id, vocabulary: preferences.dictionary)
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
        activeStyleName = sessionStyle.isLiteral && preferences.defaultStyle.isLiteral ? nil : sessionStyle.name
        pillState = .listening
        announce("Listening")
    }

    private func endDictation() {
        switch phase {
        case .pending:
            cancelDictation()
        case .listening:
            phase = .processing
            releasedAt = .now
            pill.acceptsClicks = false
            pillState = .processing
            Task { await finishDictation() }
        case .idle, .processing:
            break
        }
    }

    private func finishDictation() async {
        do {
            let heard = try await engine.finish()
            guard phase == .processing else { return } // Cancelled with Escape.
            log.info("Transcribed \(heard.count) characters, peak level \(self.peakLevel)")
            guard !heard.isEmpty else {
                finishProcessing()
                if peakLevel < silenceLevel {
                    flash(.error("No audio from \(microphoneName)"), for: .seconds(4))
                } else {
                    flash(.error("Didn't catch that"), for: .seconds(2))
                }
                return
            }

            let text = await styled(Vocabulary.apply(preferences.dictionary, to: heard))
            guard phase == .processing else { return } // Cancelled while rewriting.
            finishProcessing()
            record(heard: heard, text: text)
            await insert(text)
        } catch {
            phase = .idle
            isHandsFree = false
            hotkey.capturesEscape = false
            log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            flash(.error("Couldn't transcribe"), for: .seconds(3))
        }
    }

    private func finishProcessing() {
        phase = .idle
        isHandsFree = false
        hotkey.capturesEscape = false
        liveText = ""
    }

    /// Rewrites in the session's style with Apple Intelligence; any problem inserts what was heard instead.
    private func styled(_ transcript: String) async -> String {
        guard StyleRewriter.needsRewrite(transcript, style: sessionStyle) else { return transcript }
        guard appleIntelligence == .ready || AppleIntelligenceStatus.current == .ready else {
            log.info("Apple Intelligence unavailable; inserting the transcript as heard")
            return transcript
        }
        // Long dictations go through in chunks; any piece that fails keeps what was heard.
        let rewritten = await rewriter.styledText(transcript, style: sessionStyle, dictionary: preferences.dictionary)
        return Vocabulary.apply(preferences.dictionary, to: rewritten)
    }

    /// Adds to the menu's recent list, saved history (if on) and the Insights counts (always; no text).
    private func record(heard: String, text: String) {
        let now = Date.now
        recent.insert(Transcript(text: text, appName: targetAppName, date: now), at: 0)
        recent = Array(recent.prefix(10))
        let words = heard.split(whereSeparator: \.isWhitespace).count
        history.add(DictationStat(date: now, words: words, duration: releasedAt.timeIntervalSince(listeningSince)))
        if preferences.keepsHistory {
            history.add(HistoryEntry(
                date: now, text: text, heard: heard, appName: targetAppName,
                styleName: sessionStyle.name, processingTime: now.timeIntervalSince(releasedAt)
            ))
        }
    }

    private func cancelDictation() {
        liveText = ""
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
