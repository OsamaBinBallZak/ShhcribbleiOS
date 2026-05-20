# ShhhcribbleiOS — Claude Code context

Read this at the start of every session. It is the single source of truth for architecture decisions and hard constraints. Don't relitigate anything marked **load-bearing** without a strong reason and a note added here.

---

## What this app is

A native iOS voice-to-text note-taking app. An external trigger (Control Center widget, AirPods, Back Tap, Action Button, or keyboard extension) starts recording. The user speaks. Parakeet TDT v3 transcribes on-device via FluidAudio. The transcript is auto-saved as a Note and copied to the clipboard — or, in Phase 2, injected directly into the focused text field via the keyboard extension. Edits happen later from the note detail screen; there is no forced review step in the main flow.

**Everything runs on-device. No cloud. No API keys. No LLM post-processing.**

- **Platform:** iOS 18+ — iPhone only
- **Language:** Swift / SwiftUI
- **Transcription:** FluidAudio + NVIDIA Parakeet TDT v3 (CoreML, Apple Neural Engine)
- **Persistence:** SwiftData
- **Forked from:** OsamaBinBallZak/ShhhcribbleiOS (MIT)
- **Related:** itsHendri/Shhhcribble (Mac version — same FluidAudio stack, lessons learned documented below)

---

## Directory map

```
ShhhcribbleiOS/
├── App/
│   ├── ShhhcribbleApp.swift           # Entry point, ModelContainer, URL scheme handler
│   └── AppIntents.swift              # StartRecordingIntent, ShhhcribbleShortcuts (App Shortcuts)
├── Features/
│   ├── Recording/
│   │   ├── RecordingView.swift       # Waveform, timer, Stop + Cancel buttons
│   │   └── RecordingViewModel.swift  # @Observable, owns TranscriptionService session
│   ├── NotesList/
│   │   ├── NotesListView.swift       # Search bar, tag filter chips, note rows
│   │   └── NotesListViewModel.swift
│   ├── NoteDetail/
│   │   ├── NoteDetailView.swift      # Full note, inline editing, share
│   │   └── NoteDetailViewModel.swift
│   ├── Settings/
│   │   ├── SettingsView.swift
│   │   ├── CustomWordsView.swift     # Hotword biasing list
│   │   ├── SubstitutionsView.swift   # Find-replace rules
│   │   └── FillerWordsView.swift
│   └── Onboarding/
│       └── OnboardingView.swift      # 3 screens: what it is / add Control Center / AirPods setup
├── Models/
│   └── Note.swift                    # @Model SwiftData entity — see schema below
├── Services/
│   ├── TranscriptionService.swift    # FluidAudio actor — FRAGILE, read rules below
│   ├── AudioSessionService.swift     # AVAudioSession + route-change handling — FRAGILE
│   ├── VocabularyService.swift       # Hotwords + substitution rules, AppStorage-backed
│   └── ClipboardService.swift        # UIPasteboard snapshot/write/restore
├── Extensions/
│   ├── String+Filters.swift          # Filler word removal, substitution pass
│   └── String+TitleGeneration.swift  # First-sentence extraction for auto-title
ShhhcribbleShared/                     # Live Activity attributes + StopRecordingIntent — keep as-is from original
ShhhcribbleWidget/                     # Live Activity — extend waveform UI
ShhhcribbleKeyboard/                   # Phase 2 only — do not create until Sprint 5
```

---

## SwiftData Note model

```swift
@Model
class Note {
    var id: UUID = UUID()
    var transcript: String            // Parakeet output after filter + substitution pass
    var title: String                 // Auto: first sentence truncated to ~60 chars
    var createdAt: Date = Date()
    var duration: TimeInterval        // Recording length in seconds
    var trigger: TriggerSource        // How recording was started
    var tags: [String] = []           // Manual tags — empty by default
    var embedding: Data? = nil        // Reserved for v3 semantic search — always nil in v1/v2
}

enum TriggerSource: String, Codable {
    case controlCenter
    case airPods
    case backTap
    case actionButton
    case keyboard
    case manual
}
```

The `embedding: Data?` field must be present from the very first schema version. Populated in v3 when semantic search lands. Adding it later requires a migration.

---

## Capture flow

```
Trigger fires
    ↓
ClipboardService.snapshot()           ← save whatever is on clipboard RIGHT NOW
Recording starts (Live Activity)
    ↓
  [Cancel tap] → abort, no transcription, ClipboardService.restoreImmediately()
    ↓
[Stop tap]
    ↓
  → Empty audio → .noSpeech ("No speech detected", ~1 s neutral, dismiss) → ClipboardService.restoreImmediately()
  → Valid audio → Parakeet → substitution pass → filler filter
    ↓
Auto-save Note (auto-title from first sentence)
Write transcript to clipboard
ClipboardService.scheduleRestore(2.0)
Live Activity ends, app returns to .idle
```

Editing happens later via `NoteDetailView` (inline edit, share, delete). There is no forced review screen in the main flow — Save is automatic on Stop. If the user wants to discard, they delete the note from `NotesListView` or `NoteDetailView`.

**Never save a blank note. Never paste an empty string.**

---

## Load-bearing decisions

### Activation model — always tap-to-stop
The trigger (widget / AirPods / Back Tap) starts recording. The UI provides a Stop button. There is no push-to-talk mechanic and no toggle-mode setting. The launch IS the start. Don't add a hold-to-record gesture or a toggle preference.

### Clipboard restore — always
`ClipboardService` snapshots the clipboard before every recording. After paste, it restores the prior value with a 2-second delay, gated on `UIPasteboard.changeCount` so a manual copy during the window isn't clobbered. On Cancel or Discard, restore is immediate.

```swift
func scheduleRestore(after delay: TimeInterval) {
    let savedCount = UIPasteboard.general.changeCount
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        guard UIPasteboard.general.changeCount == savedCount + 1 else { return }
        UIPasteboard.general.string = self.priorClipboard ?? ""
    }
}
```

### "No speech detected" — named state
Empty transcription result is not an error and not a save. It is a distinct named state: brief neutral indicator (~1 s auto-dismiss), no clipboard write, no note created. Distinguish from `.error` (real failure: mic permission denied, model not loaded, FluidAudio threw).

### No LLM post-processing — ever
Parakeet output → deterministic substitution pass → deterministic filler filter → user receives exactly that. No AI reformatting. No contextual tone adjustment. No summarisation. What the user said is what they get.

### No input device picker
Route-change handlers manage the active input automatically. A manual device picker causes lifecycle bugs when users pin to a disconnected device — confirmed on Mac. Don't add one.

---

## AudioSessionService — AirPods rules (empirically verified on Mac 2026-04-23)

These are the most dangerous area of the codebase. The Mac version hit every one of these. Don't repeat them.

**Never call `setVoiceProcessingEnabled(true)` for Bluetooth.**
On iOS 17+ and macOS 14+, AirPods deliver clean audio via plain HAL I/O. Voice processing destroys output audio (music goes scratchy), forces HFP lock-in for 30+ seconds post-recording, and generates `AVAudioEngineConfigurationChange` notification storms. The guidance that AirPods need VP to deliver mic audio is iOS 16-era and is wrong today.

**Fresh `AVAudioEngine` per recording.**
Deallocate and recreate `engine = AVAudioEngine()` in `stop()`. This ensures the engine always binds to the current input device. AirPods reconnects, Continuity Mic swaps, sleep/wake all self-heal on the next trigger. Cost: ~100–200 ms cold-start. Worth every millisecond.

**Mid-recording route changes: rebuild, don't patch.**
Observe `AVAudioEngineConfigurationChange`. Tear down the tap. Reallocate the engine. Restart against the new format. Preserve any samples already captured.

**Buffer allocation per-callback, not pre-sized.**
AirPods use variable-size stereo buffers. Pre-sizing from the input format at prepare-time silently truncates → trailing words are clipped from transcription. Allocate `AVAudioPCMBuffer` per-callback from `buffer.frameLength * ratio`.

**Never run two `AVAudioEngine` instances simultaneously.**
Sharing the VP lifecycle deadlocks the main thread on `AVAudioEngineConfigurationChange`. This broke the Mac v2 onboarding mic-test screen. If you're thinking of a mic preview in onboarding — don't.

---

## TranscriptionService

Swift `actor` — thread-safe audio buffer access. One `AsrManager` loaded with Parakeet TDT v3 (~494 MB, downloaded once). Final transcription runs on `stop()`. Live preview (if implemented) polls the growing sample buffer every 3 s — do not use a pre-sized reusable buffer (see AudioSessionService buffer rule above).

The streaming `StreamingEouAsrManager` (160 ms chunks) exists in FluidAudio but we don't use it — see the "Parakeet TDT v3 (only engine)" section below for the removal rationale.

---

## ClipboardService

```swift
actor ClipboardService {
    private var priorClipboard: String?
    private var priorChangeCount: Int = 0

    func snapshot() {
        priorClipboard = UIPasteboard.general.string
        priorChangeCount = UIPasteboard.general.changeCount
    }

    func writeTranscript(_ text: String) {
        UIPasteboard.general.string = text
    }

    func restoreImmediately() {
        UIPasteboard.general.string = priorClipboard ?? ""
    }

    func scheduleRestore(after delay: TimeInterval) {
        let savedCount = priorChangeCount
        let saved = priorClipboard
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard UIPasteboard.general.changeCount == savedCount + 1 else { return }
            UIPasteboard.general.string = saved ?? ""
        }
    }
}
```

---

## App Group

App Group ID: `group.com.shhhcribble`
Set up from the very first build. Shared between:
- Main app target
- `ShhhcribbleWidget` (Live Activity)
- `ShhhcribbleKeyboard` (Phase 2 — keyboard extension)

If the group isn't set up from Sprint 1, adding the keyboard extension in Sprint 5 requires re-entitling every target simultaneously. Do it once, early.

---

## AppIntents

```swift
// StartRecordingIntent — invokable from Siri, Shortcuts, AirPods, Action Button, Control Center
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Shhhcribble Recording"
    static var description = IntentDescription("Start a voice recording in Shhhcribble")

    func perform() async throws -> some IntentResult {
        // Open app and begin recording via URL scheme or scene activation
        return .result()
    }
}

// Registered as an App Shortcut so it appears in Siri and Shortcuts automatically
// without any user setup
struct ShhhcribbleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start \(.applicationName)", "Record with \(.applicationName)"]
        )
    }
}
```

---

## Pref keys (UserDefaults / AppStorage)

| Key | Type | Default | What it does |
|---|---|---|---|
| `filterFillerWords` | Bool | `true` | Strip um/uh/hmm etc. |
| `customHotwords` | [String] | `[]` | Casing-rewrite list (NOT real engine biasing — see "Vocabulary pipeline" notes) |
| `substitutionRules` | Data (JSON) | `{}` | Key-value find-replace dictionary |
| `customFillerWords` | [String] | `[]` | User-added filler words |
| `onboardingComplete` | Bool | `false` | Show onboarding on first launch |
| `useANE` | Bool | `true` | Run model on Apple Neural Engine. **Inverted semantics**: `false` forces CPU. |

---

## UI state machine for recording

```
.idle
  → trigger fires → .recording
.recording
  → cancel tap   → .idle          (ClipboardService.restoreImmediately)
  → stop tap     → .transcribing
.transcribing
  → empty result → .noSpeech      (auto-dismiss ~1 s, ClipboardService.restoreImmediately)
  → error        → .error         (auto-dismiss ~1.6 s, ClipboardService.restoreImmediately)
  → valid text   → .saved         (persist Note, clipboard write, scheduleRestore(2.0))
.saved
  → ~1 s confirmation → .idle
```

There is no `.review` state in the main flow. Save is automatic on Stop. Edits happen later via `NoteDetailView`. Show a brief `.saved` confirmation (toast / haptic) so the user knows the note landed, then return to `.idle`.

---

## Phase 2 — keyboard extension (don't build until Sprint 5)

The keyboard extension (`ShhhcribbleKeyboard`) injects transcribed text directly into any focused text field via `UITextDocumentProxy`. It cannot access the microphone directly (Apple sandbox). Flow:

1. User switches to Shhhcribble keyboard (Globe key)
2. Taps mic button in keyboard UI
3. Keyboard signals main app via App Group shared container
4. Main app wakes (background audio session), records + transcribes
5. Main app writes transcript to App Group container
6. Keyboard reads transcript, calls `textDocumentProxy.insertText(transcript)`
7. Keyboard provides a Cancel button — tapping it writes a cancellation flag to the App Group and main app aborts

**Memory constraint:** keyboard extensions are capped at ~70 MB. Parakeet's working memory is ~66 MB on ANE. The model must run in the main app, not the keyboard extension. The keyboard only handles UI and proxy insertion.

**Known risk:** some apps (historically Electron on Mac — Claude.app, Slack, VS Code) drop `UITextDocumentProxy` writes silently. Test keyboard injection specifically against: Claude.app (iOS), WhatsApp, Apple Notes, Messages. If any app silently drops, log and surface a "copied to clipboard instead" fallback.

---

## What not to build (closed decisions)

- No push-to-talk / hold-to-record mechanic
- No toggle mode preference
- No input device picker
- No LLM post-processing of any kind
- No contextual formatting
- No cloud transcription
- No iCloud sync in v1
- No AI summaries / action items
- No speaker diarization
- No iPad / Mac (Mac version already exists)
- No Android
- No voice processing (`setVoiceProcessingEnabled`) for Bluetooth — ever

---

## Build sequence

**Sprint 1 — Foundation**
1. ✅ Re-sign all targets under your Apple Developer team (Personal Team `L9T3PX7HVH` pinned in `project.yml`)
2. ⏸ Set up App Group `group.com.shhhcribble` on all targets — **deferred to Sprint 5**, hard-blocked on paid Developer Program (Personal Team can't include `application-groups` entitlement). Until then, App Group entries are stripped from `*.entitlements` and `LiveActivityIntent` uses `openAppWhenRun: true` as a workaround.
3. ✅ Audit existing Swift files — refactor into feature folder structure above
4. ✅ Replace any UserDefaults note persistence with SwiftData `Note` model
5. ✅ Add Control Center widget — lives as `RecordControlWidget.swift` inside `ShhhcribbleWidget/` rather than a separate target

**Sprint 2 — Capture flow**
6. ✅ `RecordingView` — waveform, timer, Stop + Cancel. (`RecordingViewModel` split intentionally skipped — see "Architecture stance" below; logic lives view-local with `@State` + `TranscriptionStatus` for shared observable state.)
7. ✅ `ClipboardService` — actor with snapshot/write/restore, parked for Sprint 5 keyboard autopaste only. **NOT used by the in-app flow** — see [feedback memory](file:.claude/projects/-Users-hendri-ShhhcribbleiOS/memory/feedback_clipboard_restore_scope.md).
8. ✅ Auto-save on Stop + `.saved` confirmation toast (no Review screen — edits land in `NoteDetailView`)
9. ✅ `TranscriptionService` — FluidAudio actor, VP-free audio session. `cancelRecording()` is a real abort (drops audio, skips SwiftData write).
10. ✅ Share Sheet from `NoteDetailView` (`ShareLink`)

**Sprint 3 — Notes layer**
11. ✅ SwiftData `Note` model + `ModelContainer` setup
12. ✅ `NotesListView` — search bar (substring on transcript+title), tag filter chips (multi-select **AND**), swipe-to-delete, "Clear All", "Clear filters"
13. ✅ `NoteDetailView` — full note, inline title + transcript edit, ShareLink, delete-with-confirm, tag editor with autocomplete (sources from all-notes `@Query`)

**Sprint 4 — Settings + polish**
14. ✅ `SettingsView` — vocabulary section with NavigationLinks to `CustomWordsView`, `SubstitutionsView`, `FillerWordsView`. Filler-words toggle lives inside its own screen now. Live counts shown in the row labels.
15. ✅ `OnboardingView` — 3 screens + deep link to Control Center settings (shipped at c678245 alongside the Siri/Shortcuts/Back Tap intent registration fix)
16. ✅ Audio interruption handling (phone call) — wired via `AudioInterruptionObserver`. AirPods disconnect handled via `AVAudioEngineConfigurationChange` observer in `AudioRecorder` (rebuilds engine, preserves captured samples). Verified on device 2026-04-27.
17. ✅ Error states — `RecordingPhase` enum on `TranscriptionStatus` (`.idle`, `.recording`, `.error(RecordingError)`). Mic permission denied → "Open Settings" card. Model load failed → Retry card. Empty transcript → "No speech detected" toast (no haptic, no error UI; overlay collapses to `.idle`). The two error variants render inside the existing dark recording overlay; the overlay's visibility guard is now `status.overlayVisible`. `isRecording` is a computed property derived from `phase == .recording`.
18. Visual polish — light/dark parity ✅ (Sprint 4.5); typography pass + waveform animation refinement deferred to pre-TestFlight.

**Sprint 4.5 — pre-TestFlight polish (shipped 2026-04-27)**
A1. ✅ Recording overlay → system colour scheme. Removed the hand-tuned dark gradient and `.preferredColorScheme(.dark)` lock; overlay now follows light/dark via `Color(.systemBackground)`, muted button fills via `Color(.tertiarySystemFill)`, transcript tiers via `Color.primary.opacity(...)`. Soundwave bars + filled prominent buttons use `Color.accentColor`. Error icons gain severity colour (`.orange` for mic permission, `.red` for model failure). The `ScrollingLiveText` mask gradient keeps `.black` stops because that's the alpha channel for `.mask(_:)` — see the inline comment.
A2. ✅ Retry-button spinner. `RetryButton` is now its own private view inside `ErrorCard` with `@State var reloading` swapping label for `ProgressView` during `reloadModel()`. Disables itself while reloading so the user can't double-tap.
A3. ✅ AppStorage table in CLAUDE.md aligned with reality (`asrMode` / `useANE`).
A4. ✅ Live Activity multi-banner watch-list logged in "Known minor issues".
A5. ✅ Humanised model-load errors. New helper `humaniseModelLoadError(_:)` in [TranscriptionService.swift](ShhhcribbleiOS/Services/TranscriptionService.swift) maps common `NSURLError` codes (offline, timeout, DNS) and `NSPOSIXErrorDomain.ENOSPC` (disk full) to user-readable copy. Replaces both `String(describing: error)` call sites — one for `TranscriptionStatus.model = .error(...)` (Settings status row), one for `RecordingError.modelLoadFailed(...)` (in-overlay error card). Unknown errors fall back to `error.localizedDescription`. Raw error still goes to `os.Logger` via the `event(...)` channel for debugging.
A6. ✅ Model-download progress ring. New `@Published var modelDownloadProgress: Double?` on `TranscriptionStatus` — non-nil only during the FluidAudio `.downloading` phase (nil during `.listing` / `.compiling` / cached path). `loadModel(mode:)` passes a `DownloadUtils.ProgressHandler` to both `StreamingEouAsrManager.loadModels(to:configuration:progressHandler:)` and `AsrModels.downloadAndLoad(..., progressHandler:)`. `StartRecordingButton` overlays a `Circle().trim(from: 0, to: progress)` accent ring at 66×66 (button is 56×56) with `.allowsHitTesting(false)`. User only ever sees this on a fresh install or first switch to a not-yet-cached engine. Watch in future sessions in case it needs optimisation; user reported it works on both engines as of 2026-04-27.

**Sprint 4.5+1 — Append-to-note + markdown view (shipped 2026-04-30)**
B1. ✅ Append-to-note transcription. `TranscriptionService.recordAndTranscribe(trigger:appendingTo:)` takes an optional `UUID`; when non-nil, `commit(_:duration:trigger:appendingTo:)` calls new `NotesRepository.append(transcript:to:)` (fetches by `#Predicate { $0.id == id }`, joins with `\n\n`, leaves title untouched) instead of `insert(...)`. Toast surfaces "Added to note" with `text.append` SF Symbol so the user distinguishes from the new-note "Copied to clipboard" path. Actor stores `appendTargetId: UUID?`, cleared in the `recordAndTranscribe` `defer` alongside the existing recording-state reset. Cancel / empty / error paths inherit the clear automatically because they all flow through that defer.
B2. ✅ "Adding to: <title>" context chip. New `@Published var appendTargetTitle: String?` on `TranscriptionStatus`, populated at recording start via `NotesRepository.title(for:)`. Rendered in `RecordingOverlayView` as `AppendingToChip` — capsule, `.tertiarySystemFill` background, accent foreground, `text.append` icon, single line truncated. Display-only — tappable-abandon was deliberately rejected (Cancel button already covers that path; a third gesture is overload). 24pt horizontal padding to match the Cancel/Copy & Save button row underneath.
B3. ✅ Continue-recording mini FAB. New `NoteFocus` `@MainActor ObservableObject` in [ContentView.swift](ShhhcribbleiOS/Features/NotesList/ContentView.swift) — `@Published var activeNoteId: UUID?`, set in `NoteDetailView.onAppear`, cleared in `.onDisappear`. ContentView's bottom HStack renders a 44pt tinted-accent `ContinueRecordingButton` to the left of the play FAB whenever `activeNoteId != nil && !status.isRecording`. Spring transition on appearance/dismissal. Tapping calls `recordAndTranscribe(trigger: .manual, appendingTo: id)`. Replaced the earlier inline "Continue recording" button inside the note body, which felt heavy and was easy to miss when scrolled.
B4. ✅ Markdown view/edit auto-toggle on `NoteDetailView`. New [String+Markdown.swift](ShhhcribbleiOS/Extensions/String+Markdown.swift) — `containsMarkdownSyntax: Bool` extension via cached `NSRegularExpression` matching line-leading `# `/`## `/`### `, `- `, `* `, `\d+\. ` OR `[text](url)` anywhere. `.onAppear` sets `isEditing = !note.transcript.containsMarkdownSyntax` so plain transcripts open in the existing TextEditor and markdown-y notes open in a rendered `Text(AttributedString(markdown:options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))` view. Tapping the rendered text flips back to edit mode (`onTapGesture { isEditing = true }`). The earlier pencil/eye toolbar button was removed — tap-to-edit is the only affordance.
B5. ✅ Sub-feature B (image attachments) deliberately deferred. Per the [PR-bundling memory](file:.claude/projects/-Users-hendri-ShhhcribbleiOS/memory/feedback_pr_bundling_strategy.md), image attachments require an `Attachment` `@Model` + `@Relationship`, which forces the first `VersionedSchema` migration. That gets its own PR + TestFlight cycle so any migration regression is observable in isolation. Sprint 4.5+1 ships only the additive view-layer + service-layer changes.

**Sprint 5 — Keyboard extension (Phase 2)** — ✅ shipped 2026-05-19 / 2026-05-20

19. ✅ PREREQ — App Group + paid Developer Program signing restored (team `9W82X49JZS`).
20. ✅ `ShhhcribbleKeyboard` target with `KeyboardInputViewController` (KeyboardKit free tier renders the QWERTY surface; our toolbar with the mic button sits above it).
21. ✅ App Group microphone handoff (Darwin notifications + App Group polling, dual-transport for resilience).
22. ✅ `UITextDocumentProxy` text injection on transcript-ready signal.
23. ✅ Cancel + Stop buttons in keyboard UI.
24. ✅ Onboarding refreshed (Sprint 5 Phase H / Plan items 5+6, 2026-05-20).

**Phase J — cold-start from keyboard** — ✅ shipped 2026-05-20

J1-3. ✅ App Group + paid signing + intent-foundation pre-reqs (commits `4295213`, `dc68711`, `1df51e4`, `21946cf`).
J4. ✅ **The unlock.** `extensionContext.open` is documented Today-widget-only — iOS statically refuses it from a keyboard. Swapped to `EnvironmentValues().openURL(url)` (Itsuki's Apr 2026 pattern) and the cold-start started working immediately. Commits `2a67b20`, `03c1fc2`.
J5. ✅ Streaming ASR mode removed — only Parakeet TDT v3 now. Eliminates the 26-second CoreML cold-compile that was wedging the audio actor on first-after-install. Plus Tier 5.1 fix for live-transcript flicker (normalised-prefix snap). Commits `f625058`, `1af94e8`.
J6. ✅ VAD-based chunked transcription. Loads `FluidAudio.VadManager` alongside TDT, runs Silero VAD on incoming buffers, rotates `tdtBuffers` on detected `speechEnd` after 30 s elapsed (90 s hard cap). Fixes the long-recording memory crash. Steps A→E across commits `c1a58e8`, `19454b3`, `49b26a3`, `955c047`.
J7. ✅ Polish pass — AirPods staleness banner (`2bcc823`), keyboard-cold-start swipe-back hint (`fab173d`), onboarding refresh + CLAUDE.md docs (`466f20c`).
J8. ✅ In-app feedback feature — Settings → Feedback. Voice + optional pasted screenshot + optional note, stored as `Documents/Feedback/<uuid>/{metadata.json, screenshot.png}`. Multi-select + bulk email to `tiurihartog@icloud.com` with a `.zip` attachment of the raw folders, plus a post-send "delete from device?" prompt. See "Feedback feature" section below. Commit `79ba291` + uncommitted polish (toolbar split, append-on-tap, bulk email).

---

## Feedback feature (Sprint 5 / Phase J8)

In-app voice feedback capture for dogfooding, completely separate from the user-facing `Note` flow. Lives in `ShhhcribbleiOS/Features/Feedback/`:

- **`FeedbackStore.swift`** — file-based store rooted at `Documents/Feedback/`. Each item is a folder `<uuid>/` containing `metadata.json` (`{ createdAt, transcript, note, hasScreenshot, durationSeconds }`) and optionally `screenshot.png`. `@MainActor @Published items: [FeedbackItem]` for SwiftUI binding. Deliberately file-based, not SwiftData — these items are short-lived (collect → review → delete), no schema evolution likely, and file-based means `devicectl device copy from` and Files.app browsing both work transparently.
- **`FeedbackCaptureView.swift`** — modal capture UI. Records via raw `AVAudioRecorder` (16 kHz PCM WAV, the format TDT likes natively), then calls `TranscriptionService.transcribeOneShot(audioFileURL:)` to get the text. Whole row is tappable (not just the mic icon). Subsequent recordings APPEND to the existing transcript (don't overwrite — Tiuri's 2026-05-20 feedback). Optional clipboard-screenshot paste + free-form note. Save writes the folder + commits to the store; temp WAV is discarded (we keep only the text + the screenshot).
- **`FeedbackListView.swift`** — list of items, sorted newest first. Toolbar: "Select" (top-left, enters multi-select mode) + paperplane icon (send-all via `MFMailComposeViewController`, recipient hardcoded to `tiurihartog@icloud.com`) + "+" record-new (top-right). Tapping a row opens `FeedbackDetailView` for review + "Send to Tiuri" + delete-after-send.
- **`TranscriptionService.transcribeOneShot(audioFileURL:)`** — one-shot batch transcribe added to the actor. Loads the file with `AVAudioFile`, hands the buffer to TDT, returns text. Doesn't touch `recording` state — pure batch operation. Independent of the main TDT live pipeline.

**Access for review later** — three paths:

1. User taps "Send N" or the paperplane button → email to Tiuri with body text + a `feedback.zip` attachment containing the raw folders (built via `NSFileCoordinator(readingItemAt:options: [.forUploading])` for Apple-blessed automatic zipping).
2. Mac via `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier com.hendritiuri.shhhcribble --source /Documents/Feedback --destination ~/Desktop/feedback/`.
3. Files.app → On My iPhone → Shhhcribble → Feedback. Enabled by `UIFileSharingEnabled = true` + `LSSupportsOpeningDocumentsInPlace = true` in Info.plist.

**UX guardrails learned during the test session**:
- Global play FAB (in `ContentView`) hides while the Feedback list is on-screen so its toolbar buttons are the only record affordances. Wired via `NoteFocus.hideGlobalPlayFAB` flag, set in `FeedbackListView.onAppear` / cleared on `.onDisappear`.
- Email recipient hardcoded as `feedbackRecipientEmail` constant at the top of `FeedbackListView.swift` — change there when the recipient changes.
- After successful send (mail-compose-finished delegate fires with `.sent`), prompt the user to delete the sent items from the device.

---

## Architecture stance — modern SwiftUI (decided April 2026)

The original directory map showed a `XxxViewModel.swift` per feature. That pattern came from UIKit/early-SwiftUI and is no longer how Apple itself builds SwiftUI apps. The actual pattern in this codebase is:

- **Domain logic in services / actors** — `TranscriptionService`, `AudioRecorder`, `ClipboardService`, `AudioSessionManager`, `NotesRepository`. These are the units worth unit-testing.
- **Shared observable state in `@Observable` model objects** — `TranscriptionStatus` is the canonical example. It's effectively the app-wide VM for recording state.
- **View-local state in `@State`** — timer, search text, selected tags, focus, animation history. Don't lift these into a VM.
- **A separate `XxxViewModel.swift` is added only when**: (a) the view has non-trivial local logic worth testing in isolation, or (b) the same logic is shared across multiple views. Default is no VM.

`NoteDetailViewModel.swift` exists but is thin — most of the editing flow runs through `@Bindable note` + `@Environment(\.modelContext)`. It's kept around but isn't a template to follow.

If a future change is tempted to introduce a VM "for consistency" — don't. Add one only when you can name the unit test you'd write against it.

---

## When adding a feature

1. One feature per branch, locally
2. Verify with AirPods connected + music playing before committing
3. Update this CLAUDE.md if the change adds a new load-bearing decision or pref key
4. Merge to main, delete the branch

---

## Working notes — Sprint 1 + iteration learnings

These are gotchas and conventions discovered while building Sprint 1 + the recording UX. Read before extending.

### Build & install on a physical iPhone (CLI)

Xcode UI is fine, but Cmd-R from Xcode silently fails when the App Group entitlement is in play under a free Personal Team. Direct `devicectl` install is the reliable path during development:

```bash
xcodebuild -project ShhhcribbleiOS.xcodeproj -scheme ShhhcribbleiOS \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates -derivedDataPath /tmp/sb_build build

xcrun devicectl device install app \
  --device <iPhone UDID> \
  /tmp/sb_build/Build/Products/Debug-iphoneos/ShhhcribbleiOS.app
```

Get the device UDID with `xcrun devicectl list devices`. The `Failed to load provisioning paramter list...code=1002 "No provider was found"` warning that `devicectl` always emits is harmless — installation completes anyway.

**Full Access resets on every `devicectl install`.** When you push a new build that replaces an existing Shhhcribble on the device, iOS silently turns off Allow Full Access on the keyboard extension. The keyboard remains enabled in the keyboards list, so it's easy to miss — but cold-start from the keyboard (`extensionContext.open` / `EnvironmentValues().openURL`) will silently no-op until you go back to Settings → General → Keyboard → Keyboards → Shhhcribble and toggle Allow Full Access on again. This is iOS behaviour, not a bug in our build. Burned ~10 min debugging it during the Phase J Tier 4 verification on 2026-05-20.

### Personal Team signing — pin the team ID in `project.yml`

`xcodegen` regenerates the project on every run and **blanks out** the development team selection from the pbxproj. To stop the manual "set team in Xcode every time" loop, the Personal Team ID is pinned in [project.yml](project.yml) under each target's `settings.base`:

```yaml
DEVELOPMENT_TEAM: L9T3PX7HVH
```

That's the user's personal team. Do not commit a paid program team ID here — Personal Team is intentional for development.

### App Group + Personal Team don't mix

Personal Team accounts cannot include the `com.apple.security.application-groups` entitlement in their auto-generated provisioning profiles. With it set, Xcode "Build Succeeded" but install silently fails (no error in the navigator). The App Group entries in [ShhhcribbleiOS.entitlements](ShhhcribbleiOS/ShhhcribbleiOS.entitlements) and [ShhhcribbleWidget.entitlements](ShhhcribbleWidget/ShhhcribbleWidget.entitlements) are intentionally **stripped** for now, with a marker comment in `project.yml` so we restore them when the app moves to a paid Apple Developer Program account.

**Restore App Group when:**
1. User enrols in paid Apple Developer Program
2. Sprint 5 begins (keyboard extension needs the App Group container to coordinate with main app)

### LiveActivityIntent + Personal Team

`LiveActivityIntent.perform()` is meant to run in the main app's process when the user taps a button on a Live Activity. With a free Personal Team and **no App Group entitlement**, the cross-process routing from widget extension → main app silently fails (intent never fires). Workaround currently in place:

```swift
public static var openAppWhenRun: Bool = true
```

Both `StopRecordingIntent` and `CancelRecordingIntent` use `openAppWhenRun: true` so tapping them from the lock screen forces unlock + foreground. Comment markers in both files note when to flip back to `false` (after paid program + App Group restored).

The Cancel/Stop buttons on the lock-screen Live Activity card are now **decorative only**. The whole card is tappable via `.widgetURL(URL(string: "shhhcribble://open")!)` which deep-links into the app — user stops via the in-app overlay. This avoids relying on intent routing entirely. Restore the per-button intents in Sprint 5 when the App Group comes back.

### Diagnostic logging on physical devices

`print(...)` does **not** show up in `idevicesyslog` output — iOS forwards `print` to stdout, which only Xcode's debug console captures. For diagnostic logs that need to survive launch from `devicectl` and be readable from `idevicesyslog`, use `os.Logger`:

```swift
import os
private let diagLog = Logger(subsystem: "com.shhhcribble.diag", category: "lifecycle")
diagLog.notice("StopRecordingIntent.perform invoked, performer=\(Self.performer == nil ? "nil" : "set", privacy: .public)")
```

Mark interpolated values `privacy: .public` so they appear in the log instead of being redacted to `<private>`.

To stream from a connected iPhone:

```bash
brew install libimobiledevice    # one-time
idevicesyslog -u <iPhone UDID> --no-colors -o /tmp/sb_syslog.log
# (or) grep 'shhhcribble.diag' /tmp/sb_syslog.log
```

`--no-colors` matters: ANSI escape codes corrupt the file otherwise. Only run **one** `idevicesyslog` instance writing to the file at a time — multiple instances writing to the same file produce binary garbage.

### Live Activity widget animations

`.symbolEffect(.variableColor.iterative.reversing, …)` is unreliable in widget context on iOS 26. The fallback used in [ShhhcribbleLiveActivity.swift](ShhhcribbleWidget/ShhhcribbleLiveActivity.swift) is a **`TimelineView(.animation)`-driven custom waveform** built from primitive `Capsule` shapes. SwiftUI redraws on every timeline tick (~80 ms) and we drive bar heights from a sin wave evaluated at the timestamp. This is the documented way to get continuous animation in a widget without state churn.

Don't push high-frequency state updates to a Live Activity to drive animations. ActivityKit throttles aggressively (~2 updates/sec sustained) and the system will silently drop later updates.

### Live transcript pipeline pitfall

The Mac version computed a 60-character tail for the floating pill (`String(text.suffix(60))`). This was copied into iOS without realising the iOS overlay is full-screen and wants the **full** transcript. The sliding 60-char window broke the in-app `TypingViewModel` because `newText.hasPrefix(displayed)` failed on every partial — the typer rewound and retyped continuously. Symptom: jittery, never-settling text.

Fix in [TranscriptionService.swift](ShhhcribbleiOS/Services/TranscriptionService.swift):
- `TranscriptionStatus.partialSnippet` now receives the **full** filtered transcript.
- Live Activity gets a bounded `String(text.suffix(200))` because widget render space is tight.

The `TypingViewModel`'s rewind logic is still correct for genuine ASR revisions; it just shouldn't be triggered by our own truncation.

### Audio reactivity

[AudioRecorder.swift](ShhhcribbleiOS/Services/AudioRecorder.swift) computes RMS per buffer (~20 Hz on iPhone), scales by 12× to map normal speech to ~1.0, and runs an envelope follower (`max(scaled, smoothed * 0.78)`) for instant attack + smooth release. Published to `TranscriptionStatus.audioLevel` (0…1) which the in-app `SoundwaveBars` reads.

`SoundwaveBars` keeps an 11-slot history and shifts left on a 60 ms tick — so the bars literally show the shape of your voice over the last ~660 ms, not a stylised pulse.

The Live Activity waveform stays self-driven (sin wave via TimelineView) — pushing audio level updates through ActivityKit isn't viable.

### Model load — when, progress, errors

**When the download fires.** [ShhhcribbleApp.init()](ShhhcribbleiOS/App/ShhhcribbleApp.swift) kicks off `Task.detached(priority: .userInitiated) { try? await TranscriptionService.shared.ensureModelLoaded() }` immediately at process start — in parallel with onboarding, before the user taps anything. By the time someone gets through 3 onboarding screens the streaming model (smaller) is usually cached; TDT v3 (~494 MB) takes longer but still front-loads against onboarding rather than the play button. `recordAndTranscribe` also `async let modelReady = ensureModelLoaded()` as a defensive second trigger, so a recording started before the load finishes still resolves correctly.

**Progress reporting.** FluidAudio exposes a `progressHandler: DownloadUtils.ProgressHandler?` on `AsrModels.downloadAndLoad(...)`. The handler streams `DownloadProgress { fractionCompleted, phase }` where `phase ∈ {.listing, .downloading(completedFiles, totalFiles), .compiling(modelName)}`. We publish `fractionCompleted` to `TranscriptionStatus.modelDownloadProgress` only during the `.downloading` phase — listing is sub-second and compiling has no meaningful fraction, so they reset the published value to nil. The play-button ring binds directly to that property.

**Error humanisation.** Raw FluidAudio errors are NSError-bridged URL/POSIX errors; `String(describing: error)` dumps the entire userInfo blob (the offline case is a 1.2 KB wall of `NSURLErrorDomain` keys), which rendered as the Settings status row before Sprint 4.5. `humaniseModelLoadError(_:)` maps the common cases to short, action-oriented copy and falls back to `error.localizedDescription` for unknown errors. The raw error still goes to `os.Logger` via the diag channel for debugging — only the user-facing string is humanised.

### Parakeet TDT v3 (only engine — streaming was removed 2026-05-20)

The app uses a single ASR engine: **Parakeet TDT v3** (`AsrManager` from FluidAudio). Live partials are produced every ~700 ms by `tdtLiveTranscribe()` re-transcribing the accumulated `tdtBuffers`. On stop, a final clean transcribe runs over the full buffer for punctuated, capitalised output.

The previously-available `StreamingEouAsrManager` mode was removed in Phase J Tier 5. The dual-engine setup forced a 26-second CoreML cold-compile on first switch to TDT — `ensureModelLoaded` loaded streaming first (the default), and switching to TDT in Settings triggered `reloadModel` which unloaded streaming and downloaded+compiled TDT. The first compile on a fresh install pegged the audio actor while the user's first recording attempt was sitting there with unresponsive buttons. Removing the mode eliminates the failure window and simplifies the codebase by ~200 lines.

If we ever want streaming back, the surface area is documented in git history (search for "Phase J Tier 5"): a `case .streaming` branch in `loadModel`/`stopRecording`/`performRecording`, a `StreamingEouAsrManager` property, a `handlePartial(_:)` method, the `AsrMode` enum, and the Settings picker. Verify it handles AirPods' 24 kHz stereo VP-free before shipping any return.

### Scene-phase observer — only auto-stop on URL-scheme launches

`ShhhcribbleApp.scenePhase` observer used to call `stopRecording()` whenever the app went background. This broke the in-app flow: starting via the play button then switching apps would terminate the recording the moment the Live Activity appeared. Auto-stop is now gated:

```swift
if phase == .background && status.isRecording && status.launchedViaURL {
    Task { await TranscriptionService.shared.stopRecording() }
}
```

So URL-scheme triggers (Back Tap → Shortcut → app launch) still get the "tap iOS Back pill = commit" behaviour, but in-app starts continue across app switches.

### App Intents must live in the main app — multi-target source membership for the widget

`StartRecordingIntent`, `StopRecordingIntent`, `CancelRecordingIntent`, and `ShhhcribbleShortcuts` (the `AppShortcutsProvider`) all live in `ShhhcribbleiOS/App/Intents/` — **not** in `ShhhcribbleShared`. The four intent files are added to BOTH the `ShhhcribbleiOS` and `ShhhcribbleWidget` targets via [project.yml](project.yml) `sources:` entries, so each target compiles its own copy.

This is the only Apple-supported pattern for sharing intents between an app and an extension. Per Apple DTS ([forum thread](https://developer.apple.com/forums/thread/759160)): the `AppShortcutsProvider` and the intents it references must live in the main app target. If they live in a framework, the build emits `Metadata.appintents` inside the framework with empty `effectiveBundleIdentifiers`, iOS never registers the App Shortcut, the entry doesn't appear in the Shortcuts app, Back Tap, or Siri's matchable phrase list, and Siri falls through to its built-in app launcher (so "Start Shhhcribble" silently behaves like "Open Shhhcribble").

If you ever consider moving these back into `ShhhcribbleShared`: don't. We tried it. The metadata bundle generated for the framework with the AppShortcutsProvider inside still didn't register, even after using `AppIntentsPackage`. Multi-target source membership is the path.

`ShhhcribbleActivityAttributes` stays in `ShhhcribbleShared` — it's not an intent, just a shared model type for the Live Activity, and frameworks are fine for those.

### AppIntent perform() must NOT await long-running work

When Siri triggers `StartRecordingIntent`, Siri displays a "Working…" panel that absorbs touches in the launched app until `perform()` returns. If `perform()` (or anything it awaits) blocks for the full recording, Stop and Cancel buttons are inert and the mic feels dead because Siri still owns the foreground modal.

The pattern: `perform()` calls `await Self.performer?()`, but the performer body **dispatches a `Task.detached`** for the actual recording and returns immediately. See [ShhhcribbleApp.swift](ShhhcribbleiOS/App/ShhhcribbleApp.swift) `StartRecordingIntent.performer = { @MainActor in ... }`.

The performer also flips `TranscriptionStatus.shared.phase = .recording` synchronously on `MainActor` before dispatching, so the overlay covers the launch flash before the actor hop.

### AudioInterruptionObserver — Siri handoff grace window

Siri's audio session is briefly active when our intent fires, and a transient `.began` interruption can arrive right after our session activates as the contexts swap. Without filtering, that killed Siri-launched recordings after ~1 s.

[AudioInterruptionObserver.swift](ShhhcribbleiOS/Services/AudioInterruptionObserver.swift) records `recordingStartedAt` (set/cleared from `TranscriptionService.recordAndTranscribe` and `stopRecording`/`cancelRecording`) and ignores `.began` interruptions that arrive within 1.5 s of that timestamp. Real interruptions (phone calls, alarms) always arrive well outside that window.

### AudioSessionManager — release prior owner before claiming

[AudioSessionManager.configure()](ShhhcribbleiOS/Services/AudioSessionManager.swift) calls `setActive(false, .notifyOthersOnDeactivation)` before `setCategory`, and `activate()` retries once after 300 ms if the first `setActive(true)` throws. This is defensive cover for the Siri-launched path: Siri's session can still be active during its dismissal animation, and a single un-retried activate sometimes fails silently — the engine starts but captures no audio.

### AudioRecorder — per-callback buffer copy + route-change rebuild

`AudioRecorder.installTap` uses `bufferSize: 0` (let `AVAudioEngine` pick the natural delivery size — variable on AirPods). The tap closure allocates a **fresh** `AVAudioPCMBuffer` sized to `buffer.frameLength` and `memcpy`s frames in before yielding via `onBuffer`. Hardcoded buffer sizes (the original `2560`) silently truncate trailing audio on AirPods because the tap reuses backing storage and Bluetooth delivers variable-size stereo buffers — pre-sized taps clip the last frames of an utterance.

The `engine` property is a `var`, not a `let`: an `AVAudioEngineConfigurationChange` notification observer rebuilds it from scratch on route change (AirPods disconnect, Continuity Mic swap). Per CLAUDE.md AirPods rules, "rebuild, don't patch" — surgically updating the existing engine deadlocks. Already-captured samples are preserved naturally because TDT accumulates in `tdtBuffers` and streaming has already fed buffers to the FluidAudio manager. Logs surface under `os.Logger(subsystem: "com.shhhcribble.diag", category: "audio")`.

### ClipboardService is keyboard-extension only

`Services/ClipboardService.swift` exists but is **not wired into the in-app recording flow**. The in-app flow writes transcripts directly to `UIPasteboard.general.string` on the main thread (in `commit`, `handlePartial`, `tdtLiveTranscribe`) and leaves the clipboard alone afterwards — the user wants the transcript to stick.

Two reasons not to revert this:
1. The user explicitly didn't want the prior clipboard restored after a normal recording.
2. Routing live-partial writes through the actor added enough latency that backgrounded paste targets only ever saw early words. Direct main-thread writes match the original behaviour.

Snapshot / `scheduleRestore` / `restoreImmediately` are reserved for the Sprint 5 keyboard-extension autopaste path, where the keyboard injects via `UITextDocumentProxy.insertText` and then needs to put the user's prior clipboard back. Don't re-introduce those calls inside `TranscriptionService`.

### Cancel is a real abort

`TranscriptionService.cancelRecording()` is distinct from `stopRecording()`. Cancel:
- sets the `cancelled` flag, stops the recorder + cancels feed/live tasks
- drops `tdtBuffers`, clears `lastPartial`
- resumes the awaiter with empty text

The post-finish path in `recordAndTranscribe` checks `cancelled` and returns early, **before** `commit` — so no SwiftData write, no toast, no clipboard touch. The Cancel button in `RecordingView` calls `cancelRecording`. The Stop button still calls `stopRecording` (which finalises transcription and saves).

### Vocabulary pipeline — substitutions, hotwords, custom fillers

Final transcript is built by three deterministic passes, in order:

1. **Filler-word filter** — built-in regexes in [String+Filters.swift](ShhhcribbleiOS/Extensions/String+Filters.swift) plus user-added `customFillerWords` (whole-word, case-insensitive). Gated by the `filterFillerWords` toggle.
2. **Substitution pass** — [String+Substitutions.swift](ShhhcribbleiOS/Extensions/String+Substitutions.swift) reads `substitutionRules` (Data, JSON-encoded `[String: String]`) AND synthesises one rule per `customHotwords` entry as `H.lowercased() → H`. Explicit substitutions win on key collision. Whole-word, case-insensitive.

All three pipeline sites in `TranscriptionService` (final stop at ~line 472, TDT live at ~507, streaming partial at ~570) run filler → substitution in that order so substitutions don't get stripped.

**FluidAudio biasing limitation.** `customHotwords` is implemented as a casing-rewrite, NOT real engine biasing. FluidAudio exposes `configureVocabularyBoosting` only on `SlidingWindowAsrManager`; the manager we use (`AsrManager` for TDT) doesn't have it. To get real biasing for misrecognised words (not just casing) we'd need to swap to `SlidingWindowAsrManager` — out of scope for v1. The Settings copy reflects this honestly: "Best for proper nouns Parakeet hears correctly but doesn't capitalise. For mis-transcribed words, use Substitutions instead."

### Recording phase state machine

`TranscriptionStatus.phase: RecordingPhase` is the single source of truth for the overlay:

- `.idle` — overlay hidden.
- `.recording` — main capture UI (waveform + live transcript + Cancel/Copy & Save).
- `.error(RecordingError)` — sticky until user taps Dismiss / Open Settings / Retry. Cases: `.micPermissionDenied` (preflight in `recordAndTranscribe` before recording flag flips), `.modelLoadFailed(String)`, `.other(String)`.

Empty transcript ("no speech detected") is **not** a phase. It's surfaced via `ToastManager.shared.show("No speech detected", systemImage: "waveform.slash")` while the overlay collapses to `.idle` through the normal defer path. No haptic, no clipboard write, no Note saved. Toast was chosen over a full-screen card because the recording overlay was disproportionate weight for a 1-second non-error signal — the existing toast pattern (used for "Copied to clipboard") is the right surface.

`isRecording: Bool` is a computed property over `phase == .recording`. The `defer` block in `recordAndTranscribe` only collapses to `.idle` when phase is still `.recording` — sticky error states survive teardown so the overlay stays visible. Mic permission preflight uses `AVAudioApplication.requestRecordPermission()` (iOS 17+ async API).

---

## Known minor issues / future polish

Logged at the end of Sprint 4 — none of these block TestFlight, but flagging so they're not re-discovered.

- **Retry button has no progress feedback.** In the model-load-failed error card, tapping Retry runs `TranscriptionService.shared.reloadModel()` (3–5 s on a cold load) before dismissing the overlay. During that wait the button stays tappable and there's no spinner — user has no signal that anything is happening. ~10 lines: add an `@State var reloading = false` to `ErrorCard`, swap the label for a `ProgressView` while reloading, disable the button. Low priority because model-load failure is rare on a healthy device.
- **`SubstitutionPass.currentRules()` rebuilds the dict per call.** [String+Substitutions.swift](ShhhcribbleiOS/Extensions/String+Substitutions.swift) reads `UserDefaults` and JSON-decodes `substitutionRules` every time it's called. During streaming partials that's ~3–5 invocations/sec. Imperceptible at current dict sizes (single-digit entries) but the cleaner shape is a cached snapshot invalidated on AppStorage change. Defer until profiling shows it.
- **Custom Words footer copy** — "Auto-corrects the casing of these words in transcripts. Best for proper nouns and brand names that Parakeet hears correctly but doesn't capitalise. For mis-transcribed words, use Substitutions instead." Pending a real on-device read; tighten if it reads off.
- **TDT hallucinates phantom words on silence.** In Parakeet TDT v3 mode, recording near-silence produces a phantom transcript that always starts with "Recording" and is sometimes followed by a single word like "yeah" or "hello". Streaming mode does not exhibit this — it stays at blank tokens. Likely cause: the TDT decoder's language-model prior dominates when the acoustic signal is weak (a known RNN-T / TDT failure mode), and the start-of-recording click + room tone in the first ~0.5 s maps to a high-frequency English word ("Recording" is plausible). **Possible fixes (not yet attempted):** (a) RMS-energy VAD gate that skips transcription when the buffer never crosses a threshold; (b) drop the first ~200 ms of buffer before handing to TDT to skip the start-click. Neither is trivial — VAD needs threshold tuning across mic types (built-in vs AirPods vs Continuity), and the leading-trim doesn't help mid-utterance silence. Defer until enough user reports surface to justify the tuning effort.
- **Live Activity multi-banner stacking — watch-list.** During Sprint 4, recording back-to-back occasionally left an orphaned Live Activity banner from the previous session, leaving two banners visible. Fixed in [ShhhcribbleActivityManager.swift](ShhhcribbleiOS/Services/ShhhcribbleActivityManager.swift) by (a) reaping any pre-existing activities at `start()` time and on app foreground via `reapOrphanedActivities()`, and (b) inserting a 3 s delay before `Activity.end(...)` so the dismissal animation completes before a new activity starts. User confirmed banners now dismiss cleanly. **If it recurs:** likely either `reapOrphanedActivities` isn't iterating every `Activity<ShhhcribbleActivityAttributes>.activities` instance (e.g. activities started in a previous app session that were never observed by this process), or the `end()` / `start()` race is back (rapid double-trigger from Siri or a stuck Control Center widget). Investigate by logging `Activity.activities.count` at every start/end, and by adding a fingerprint per activity so pre-existing ones can be distinguished from in-flight ones.

---

*Last updated: 2026-05-20 — Sprint 5 / Phase J shipped end-to-end. Keyboard cold-start works (`EnvironmentValues().openURL` was the unlock). Streaming engine removed; single Parakeet TDT v3 with VAD-based chunk rotation. Live transcript flicker fixed via four-case hybrid in `TypingViewModel`. In-app feedback feature added under `ShhhcribbleiOS/Features/Feedback/`. See `HANDOFF.md` for current state, `backlog.md` for outstanding polish.*
