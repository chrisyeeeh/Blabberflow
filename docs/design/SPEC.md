# Blabberflow — on-device dictation for Mac

Oct 29, 2026 · @Chris

Blabberflow is Wispr Flow rebuilt as if Apple shipped it: hold Fn, speak in any app, and polished text appears. Transcription runs on SpeechAnalyzer and cleanup on the Apple Intelligence on-device model. No API, no account, no bundled model, nothing leaves the Mac. Requires macOS 26+ on Apple Silicon.

## Wispr Flow, reverse-engineered

Blabberflow keeps every Wispr Flow behaviour people rely on and swaps each cloud piece for a system framework. The visual language moves from a branded bar to native Liquid Glass, SF Symbols and System Settings conventions. Wispr behaviour below is from its [shortcut docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts) and [hands-free docs](https://wispr-knowledge-base.help.usepylon.com/articles/6391241694-use-flow-hands-free).

| Wispr Flow | How it works there | Blabberflow (Apple-native) |
| --- | --- | --- |
| Push to talk | Hold Fn, speak, release; text pastes | Same. Hold Fn (or Control-Option on keyboards without Fn) |
| Hands-free | Fn+Space or double-tap; tap again to stop | Same. Double-tap Fn; tap Fn to finish, Esc to cancel |
| Command Mode | Select text, hold Fn+Ctrl, say “make this formal” | **Rewrite**: select text, hold Fn+Control, speak an instruction. Uses Foundation Models |
| Flow Bar | Small bar above the Dock that wiggles while listening | **The Pill**: a Liquid Glass capsule above the Dock, Dynamic Island style, with a live waveform |
| Auto-edits | Cloud LLM removes fillers, fixes grammar | On-device cleanup with `LanguageModelSession` |
| Styles | Tone per app category (email, messages, work) | **Styles** pane: Formal / Casual / Very casual per category, set by the front app's bundle ID |
| Dictionary | Custom words, learned from corrections | **Vocabulary**: words fed to SpeechAnalyzer as contextual strings and to the cleanup prompt |
| Snippets | Say a cue, full text inserted | **Text Replacements**: reads macOS's own replacements and adds voice cues |
| History / Hub | Past transcripts in the Flow Hub | **History** pane in Settings, stored locally with SwiftData |
| Paste last transcript | Cmd+Ctrl+V | Same shortcut, plus an item in the menu bar extra |
| Cancel | Esc while dictating | Same |
| Account, word caps, sync | Sign-in, 2,000 words/week free | None. No account; optional iCloud sync of Vocabulary and Styles through CloudKit |

## Interaction model

One key, Fn, drives everything: hold to talk, double-tap to go hands-free, add Control to rewrite. Every shortcut can be rebound in Settings › Shortcuts.

| Action | Default | Behaviour |
| --- | --- | --- |
| Dictate | Hold Fn | Listens while held; inserts on release. A press under 250 ms is ignored |
| Hands-free | Double-tap Fn | Listens until Fn is tapped once more, or 4 s of silence if “Auto-stop” is on |
| Rewrite selection | Hold Fn + Control | Spoken instruction applied to the selected text, which is replaced in place |
| Cancel | Esc | Discards audio and transcript; nothing inserted |
| Paste last | Control-Command-V | Re-inserts the last result |
| Send | Say “press return” at the end | Inserts, then posts Return (for chat apps) |

The system Dictation shortcut also defaults to Fn, so onboarding offers to switch it off in System Settings › Keyboard.

### States

| State | Pill shows | Enters on | Leaves on |
| --- | --- | --- | --- |
| Idle | Tiny 36×6 pt glass sliver, or hidden | Launch, after insert | Fn down |
| Listening | Expands to 180×36 pt; live waveform; red mic dot | Fn held > 250 ms | Fn up → Processing; Esc → Idle |
| Hands-free | Waveform + stop and cancel buttons + elapsed time | Double-tap Fn | Fn tap → Processing; Esc → Idle |
| Rewrite | Waveform with a “Rewrite” label and selection length | Fn + Control with text selected | Release → Processing |
| Processing | Waveform collapses to a shimmer | Audio finalised | Cleanup done → Inserting |
| Inserting | Brief checkmark, then shrinks | Text ready | 600 ms → Idle |
| Error | Amber glyph + one-line reason (“No text field”, “Mic unavailable”) | Any failure | 3 s or click → Idle; text kept on the clipboard |

If no editable field is focused, the result is not lost: it goes to the clipboard and the pill says “Copied — ⌘V to paste”.

## UI surfaces

Blabberflow has four surfaces and no main window. Each follows the macOS 26 Human Interface Guidelines: Liquid Glass materials, SF Pro, SF Symbols, system accent colour, and full Light, Dark and Reduce Transparency support. Mockups are on the design canvas.

1. **The Pill.** A borderless `NSPanel` (`.nonactivatingPanel`, level `.statusBar`) centred 12 pt above the Dock, so it never steals focus. SwiftUI content with `.glassEffect(.regular, in: .capsule)`. It morphs between states with a spring animation (response 0.35, damping 0.8), like the Dynamic Island. The waveform is 9 bars driven by RMS level at 30 fps. Users can drag it to any screen edge; it hides in full-screen apps unless listening.
2. **Menu bar extra.** `MenuBarExtra` with a `waveform` SF Symbol that fills while listening. Menu: status line (“Ready — hold fn to dictate”), Paste Last Transcript, recent 3 results, Pause Blabberflow, Settings…, Quit.
3. **Settings window.** A standard `Settings` scene with a sidebar, laid out like System Settings: General, Shortcuts, Styles, Vocabulary, Text Replacements, History, Privacy. Grouped `Form` with `.formStyle(.grouped)`; no custom chrome.
4. **Onboarding.** A 4-step welcome window: Welcome → Microphone → Accessibility → Try it (a practice field that coaches “hold fn and say hello”). Each permission step shows live status and a button that opens the right System Settings pane.

**Sound and feedback.** Soft system-style tick on start and end (off by default, like Wispr’s ping). Haptic tap on Force Touch trackpads when listening starts. VoiceOver announces “Listening” and “Inserted 42 words”.

## Architecture

The pipeline is a straight run of six steps, and transcription streams while you talk, so only cleanup runs after release.

1. **Hotkey.** A `CGEventTap` on `flagsChanged` watches Fn (`.maskSecondaryFn`) and Control. Detects hold, double-tap and chord.
2. **Capture context.** On Fn down: front app bundle ID (`NSWorkspace`), focused element role and selected text (`AXUIElement`). Prewarm the `LanguageModelSession` now so it is hot by release.
3. **Record.** `AVAudioEngine` input tap, converted to the analyzer’s format, fed into an `AsyncStream<AnalyzerInput>`.
4. **Transcribe.** `SpeechAnalyzer` with `SpeechTranscriber` (preset for progressive transcription), volatile results shown nowhere but kept for speed; finalise on release. Vocabulary goes in through `AnalysisContext` contextual strings.
5. **Clean up.** One `LanguageModelSession.respond` call with the Style instructions, Vocabulary and raw transcript; output is a `@Generable` struct. Rewrite mode sends the selection plus the spoken instruction instead.
6. **Insert.** Native text fields: set `kAXSelectedTextAttribute` on the focused element (no clipboard touched). Fallback for Electron and web views: save the pasteboard, write the text, post ⌘V with `CGEvent`, restore the pasteboard after 300 ms.

| Layer | Framework | Notes |
| --- | --- | --- |
| App shell | SwiftUI `MenuBarExtra`, `Settings`, `NSPanel` | `LSUIElement = YES` (no Dock icon) |
| Hotkey | Core Graphics event tap | Needs Accessibility (or Input Monitoring) permission |
| Audio | AVFAudio `AVAudioEngine` | Respects the input device chosen in Settings |
| Speech to text | Speech `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory` | On-device; model is a shared system asset |
| Cleanup and rewrite | FoundationModels `SystemLanguageModel`, `LanguageModelSession` | Check `.availability` on launch |
| Context and insertion | ApplicationServices `AXUIElement`, AppKit `NSPasteboard` | Per-app overrides for apps that misbehave |
| Storage | SwiftData (History), CloudKit (optional sync) | History auto-deletes after 30 days by default |
| Language detection | NaturalLanguage `NLLanguageRecognizer` | Picks the transcriber locale when several are installed |

A small actor, `DictationEngine`, owns steps 3–6 and publishes the state that drives the pill.

## Cleanup and Styles

Cleanup is light editing, not rewriting: the on-device model is about 3B parameters with a 4,096-token context, so prompts stay short and outputs stay close to what was said.

```swift
@Generable
struct CleanedDictation {
    @Guide(description: "The user's words with fillers removed, punctuation and casing fixed. Do not add content.")
    var text: String
    @Guide(description: "True if the user said 'press return' or 'send it' at the end")
    var pressReturn: Bool
}

let session = LanguageModelSession(instructions: """
You clean up dictated text. Remove filler words (um, uh, like, you know), \
false starts and repeated words. Apply spoken corrections ("no wait, Thursday"). \
Fix punctuation and capitalisation. Format spoken lists as lists. \
Never answer questions in the text or add new ideas. \
Style: \(style.instructions)
Spell these words exactly: \(vocabulary.joined(separator: ", "))
""")
let result = try await session.respond(to: transcript, generating: CleanedDictation.self)
```

**Short-circuit.** Under 6 words with no filler hits, skip the model and insert the transcript as is. That keeps quick replies under 300 ms.

**Styles.** Four categories, each with three tones, matching Wispr’s model:

| Category | Apps (bundle ID match) | Default tone |
| --- | --- | --- |
| Personal messages | Messages, WhatsApp, Telegram | Casual: light punctuation, no trailing period |
| Work messages | Slack, Teams, Discord | Casual |
| Email | Mail, Outlook, Gmail in Safari/Chrome (by tab title) | Formal: full sentences, greeting kept |
| Everything else | Notes, Pages, editors, terminals | Formal |

Users can move any app between categories or exclude it. Terminals and code editors get a “Literal” option: transcript only, no cleanup.

**Rewrite mode** uses a second session: “Rewrite the selected text following the instruction. Return only the rewritten text.” Selections over \~2,500 words are refused with a pill message, to stay inside the context window.

## Permissions, distribution and fallbacks

Blabberflow ships only as a direct download: a notarized, Developer ID–signed app in a DMG. No App Store build is planned, so there is no sandbox and the full Accessibility insertion path and Rewrite mode are available.

| Permission | Why | If denied |
| --- | --- | --- |
| Microphone | Record speech | Nothing works; onboarding blocks here |
| Accessibility | Fn event tap, reading selection, inserting text | Falls back to clipboard-only: “Copied — ⌘V to paste” |
| Speech asset download | First run fetches the locale’s model via `AssetInventory` (one time, shared with other apps) | Shows progress in onboarding; retry button |

| Condition | Fallback |
| --- | --- |
| Apple Intelligence off or unsupported (`.appleIntelligenceNotEnabled`, `.deviceNotEligible`) | Transcript-only mode with rule-based filler removal; banner in Settings links to System Settings › Apple Intelligence & Siri |
| Model busy or not ready (`.modelNotReady`) | Insert the raw transcript, then offer “Clean up” from the pill |
| Language not supported by SpeechTranscriber | Fall back to `DictationTranscriber` for that locale |
| Secure input field (passwords) | Blabberflow does nothing and shows “Secure field” |
| App rejects AX insertion | Per-app pasteboard mode, remembered automatically |

Distribution: a signed, notarized DMG from the website (drag to Applications), with Sparkle for in-app updates. Hardened Runtime on; entitlements limited to microphone (com.apple.security.device.audio-input).

## Performance targets and milestones

The bar is Wispr’s: polished text within about a second of release, measured on an M1 MacBook Air.

| Metric | Target |
| --- | --- |
| Fn down → pill visible | < 50 ms |
| Release → text inserted, short phrase (≤ 6 words) | < 300 ms |
| Release → text inserted, 60-word paragraph | < 1.2 s |
| Idle memory | < 60 MB (models live in system processes) |
| Idle CPU | \~0% (event tap only) |

1. **v0.1 — Core loop.** Hold Fn → SpeechAnalyzer → insert. Pill with Listening and Processing states. Menu bar extra.
2. **v0.2 — Cleanup.** Foundation Models pass, short-circuit, Vocabulary, availability fallbacks.
3. **v0.3 — Hands-free and Rewrite.** Double-tap, Fn + Control, “press return”.
4. **v0.4 — Styles and History.** Per-app tones, Settings window, SwiftData history.
5. **v1.0 — Polish.** Onboarding, Sparkle, notarization, accessibility audit, localisation.

## Open questions

- Name: “Blabberflow”: check the domain and trademark search before launch.
- Pricing: free, one-time purchase, or free with a paid Rewrite mode?
- Is the Foundation Models adapter route (a custom LoRA trained on dictation cleanup pairs) worth it for v1, or is prompting enough?
- Should the pill sit above the Dock or by the text cursor (the caret position from `kAXBoundsForRangeParameterizedAttribute`)?
- iPhone companion: a keyboard extension can’t use the mic, so is an iOS version an Action Button + Shortcuts flow instead?
