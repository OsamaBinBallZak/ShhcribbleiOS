# Handoff — end of 2026-05-22 session

*Read this once at session start, then `backlog.md`. This handoff replaces the older 2026-05-20 Sprint 5/Phase J doc — that work is now ancient history; everything since is documented below.*

---

## TL;DR

Branch `claude/laughing-hypatia-86b85c` is at `<HEAD>` (see `git log --oneline`). All work pushed to `origin` = `OsamaBinBallZak/ShhcribbleiOS` on GitHub.

**This session shipped:** the recording-state desync fix (backlog #2 — root cause found via parallel research agent + Opus model + the production-traffic console log), keyboard pill redesign (visual + App-Group plumbing for live audio bars and partial transcript), and a bunch of UX polish on it (press feedback, fade gradient, always-visible waveform, button size + colour tuning).

**What's still open at end of session:** warm-mode auto-paste — needs reproduction with console capture next session. The cold-start auto-paste path works; the warm-mode path (engine already alive, no app foreground) doesn't insert the transcript on stop.

**Next thing to tackle:** backlog #12 + #13 — Superwhisper-parity cold-start UX. Full-screen takeover page + bundled Shortcut that wraps `ToggleRecordingIntent` so back-tap / action button / lock screen can dictate without ever foregrounding the app.

---

## Sessions chronological — what landed since 2026-05-20

- **2026-05-21 morning**: Sprint 6 architectural deepening shipped. `TranscriptionService` (1134 LOC god actor) split into `TextEngine` + `AudioInput` + `RecordingCoordinator` + `TranscriptionStatus`. 4 commits + CLAUDE.md doc update.
- **2026-05-21 afternoon**: Sprint 7 Feedback redesign shipped (backlog #6). Capture view's Cancel + Save → Discard + Send. "Sent ✓" pill on rows. Delete-after-send prompt removed. Bulk-send demoted into "…" menu.
- **2026-05-21 afternoon**: FB-3 (mic icon), FB-1 (KeyboardKit auto-cap reset), FB-4 (model-state-aware empty state with download/compile progress).
- **2026-05-21 evening**: Sprint 8 WIP — keyboard pill visual redesign + App Group plumbing for live audio level + partial transcript. Visual landed but auto-paste was broken (#2 desync re-emerged).
- **2026-05-22 (this session)**: Recording-state desync fix (A+B+C in `a86d310`). Keyboard pill polish (press feedback, fade gradient, always-visible waveform, lighter pill background, no left mic icon).

---

## Open / unresolved at end of session

### Warm-mode auto-paste (backlog #21, downstream of #2)

User repro'd today after the A+B+C fix:
- Cold-start path: keyboard mic tap → main app foregrounds → record → swipe back → transcript auto-pastes. ✅
- Warm path: engine warm, user stays in Notes → keyboard mic tap → record → keyboard pill stop tap → **no auto-paste**. ❌

After Fix A+B+C, the desync itself is gone (no more "Stop: already stopping or not recording" loop), but the warm-mode-specific transcript handoff still fails. Best guess: either `KeyboardBridge.writeTranscript` doesn't fire (trigger isn't `.keyboard` somehow), or the keyboard's `consumeAndInsertTranscriptIfReady` isn't running fast enough / at all in warm path.

**Next session, first thing:** install with `--console` attached, repro the warm path, grep the log for the missing event. Likely a small fix once we see which event doesn't fire.

### Gray space above the pill varies by host app (backlog #20)

Notes shows a tall gray strip above the pill; WhatsApp wraps it tight. Diagnosed as iOS reserving inset for autocorrect candidates that we don't render into. Decided to accept for now — the pill itself is fine within its own region.

If we want to fix later: implement our own row inside that strip (predictive completions, or extra live-transcript overflow during recording). Documented in backlog #20.

---

## What to tackle next session

User explicitly named the next focus:

> "the deep links for the keyboard and the shortcuts"

That maps to **backlog #12 + #13** — Superwhisper-style cold-start UX:

1. **#12**: Full-screen "Shhhcribble is recording — swipe back to keyboard" takeover view shown after keyboard cold-start launches the app. Replaces our current SwipeBackHint pill. Inspired directly by Tiuri's Superwhisper iOS screenshots earlier in this conversation (sent 2026-05-21).

2. **#13**: Ship a pre-built `.shortcut` file bundled in the app, wrapping `ToggleRecordingIntent`. Tiuri sent screenshots of Superwhisper's "Toggle Superwhisper Dictation" shortcut. Same shape:
   - `Toggle Recording` action (our `ToggleRecordingIntent`)
   - `If (result is anything) { ... } Otherwise { copy → notification → vibrate }`
   - Deep link `shortcuts://import-shortcut?url=<file>&name=...` for one-tap install
   - The shortcut runs in the Shortcuts daemon, NOT in Shhhcribble's app → bypasses the iOS-26 foreground-on-URL-open friction entirely

   Onboarding gets two buttons:
   - "Enable Shhhcribble keyboard" → deep-link to Settings → General → Keyboard → Keyboards (already exists)
   - "Install dictation shortcut" → `shortcuts://import-shortcut?...` deep link (new)

   Once the shortcut is installed, the keyboard's voice button can route through it (URL: `shortcuts://run-shortcut?name=Toggle%20Shhhcribble%20Recording`). `KeyboardBridge.recordURL` already has this URL hardcoded — we just need to actually ship the .shortcut file and the install UI.

Also worth doing while we're in there:
- **FB-7** onboarding Full Access info-card (paragraph explaining what Allow Full Access does, why it's safe). Standalone but related — keyboard onboarding revamp territory.

---

## Hard-won lessons / gotchas — do NOT relitigate

### 1. CWD trap (specific to this dev setup)

The repo has a git worktree at `.claude/worktrees/laughing-hypatia-86b85c/`. **Bash commands from this session keep resetting their CWD to `/Users/tiurihartog/Hackerman/ShhcribbleiOS` (the main repo root, NOT the worktree)** between tool calls. This means:

- `xcodebuild -project ShhhcribbleiOS.xcodeproj ...` without an explicit `cd` builds the OLD main-branch project, not your changes
- `grep` without an explicit `cd` searches the old code
- `git status` without explicit `-C` shows the main repo's status

**Always prefix bash commands** with `cd /Users/tiurihartog/Hackerman/ShhcribbleiOS/.claude/worktrees/laughing-hypatia-86b85c && ...`. Or pass `-C <path>` to git commands.

This bit us multiple times today — once where I installed the "real worktree build" and the user kept seeing the old binary because my xcodebuild was actually building from main. Don't skip the cd.

### 2. iOS keyboard extension binary cache

Even after `devicectl install` succeeds, iOS sometimes keeps the OLD keyboard extension binary in memory and uses it instead of the new one. The MAIN APP refreshes correctly; the KEYBOARD EXTENSION can lag arbitrarily.

**Symptoms**: pill renders with old layout / old code, but the main app's UI is updated. Diagnostic logs you added to the keyboard never fire.

**Forced refresh**: `devicectl uninstall app` + `devicectl install app`. This wipes the entire app container including the FluidAudio model cache (~494 MB re-download). Or: manually toggle keyboard off + on in Settings → General → Keyboard → Keyboards.

Plan for it. Don't waste 20 minutes debugging "my code change didn't work" before checking whether the keyboard's even running the new binary.

### 3. iOS extension state nuking

`devicectl uninstall app` wipes:
- The app container (incl. cached model files → re-download required)
- Allow Full Access permission on the keyboard (needs re-enabling)
- Keyboard registration sometimes (varies)

When testing keyboard cold-start: after install, the user needs to re-enable Allow Full Access. Tell them to check explicitly. Tiuri hit this multiple times.

### 4. KeyboardKit's `state.keyboardContext` is async-initialised

`KeyboardInputViewController.viewDidLoad` triggers `state.setup(for: self)` via `DispatchQueue.main.async`. Accessing `state.keyboardContext.X` synchronously inside our subclass's `viewDidLoad` crashes the extension silently (iOS respawns it; no crash report; your `KeyboardBridge.debug` line never fires either).

**Put context config in `viewWillSetupKeyboardView`**, which runs from `viewWillAppear` AFTER the async setup completes. The FB-1 keyboard autocap fix is wired this way.

### 5. KeyboardKit `isAutocapitalizationEnabled` can persist false silently

KeyboardKit's `KeyboardSettings.isAutocapitalizationEnabled` is `@AppStorage`-backed. If it ever gets persisted as `false` (corruption, prior version), `KeyboardContext.init` calls `syncAutocapitalizationWithSetting` and hard-sets `autocapitalizationTypeOverride = .none`. Result: keys always lowercase, shift no-op, no sentence-start cap.

**Defensive reset in `viewWillSetupKeyboardView`**:
```swift
let context = state.keyboardContext
context.keyboardCase = .auto
context.autocapitalizationTypeOverride = nil
context.settings.isAutocapitalizationEnabled = true
```

Already in code (FB-1 fix). Don't remove.

### 6. Three concurrent keyboard signals

Pressing the keyboard's voice button fires three things into the main app:
1. Darwin `darwinStart` notification
2. App Group `pttSignal=start` write
3. (if engine cold) `extensionContext.open` of `shhhcribble://keyboard`

All three trigger `RecordingCoordinator.recordAndTranscribe` paths. Pre-Fix-A this caused races that desynced the recording flag. Now all three funnel through `RecordingCoordinator.keyboardRecordAndTranscribe()` which dedupes with a 250ms window.

If you add a new keyboard trigger path, route it through that wrapper too. Don't call `recordAndTranscribe(trigger: .keyboard)` directly from keyboard-side code.

### 7. `performRecording`'s defer block lives at the TOP

After Fix B (this session), the cleanup defer in `performRecording` is registered immediately after `recording = true`, BEFORE the first `try Task.checkCancellation()`. Don't move it back down — that's the bug we just spent hours fixing.

---

## Build / install / launch commands (paste-ready)

Always-prefix every command with `cd`:

```bash
# Build for device (must run from worktree)
cd /Users/tiurihartog/Hackerman/ShhcribbleiOS/.claude/worktrees/laughing-hypatia-86b85c && \
  xcodebuild -project ShhhcribbleiOS.xcodeproj -scheme ShhhcribbleiOS \
    -destination 'generic/platform=iOS' -configuration Debug \
    -allowProvisioningUpdates -derivedDataPath /tmp/sb_build build 2>&1 \
    | grep -E "BUILD (SUCCEEDED|FAILED)|error:" | head -10

# Install (preserves model cache)
xcrun devicectl device install app --device A9195A77-601A-54C1-B3BD-659FBFE1DC54 \
  /tmp/sb_build/Build/Products/Debug-iphoneos/ShhhcribbleiOS.app

# Uninstall (nukes app data — only when you NEED to force-refresh the keyboard extension)
xcrun devicectl device uninstall app --device A9195A77-601A-54C1-B3BD-659FBFE1DC54 \
  com.hendritiuri.shhhcribble

# Launch with console
xcrun devicectl device process launch --device A9195A77-601A-54C1-B3BD-659FBFE1DC54 \
  --console --terminate-existing com.hendritiuri.shhhcribble

# Regenerate Xcode project after project.yml changes
xcodegen generate
```

Device must be unlocked + on USB for `devicectl process launch --console` to capture stdout. Bundle ID is `com.hendritiuri.shhhcribble`. Team `9W82X49JZS` (paid program).

---

## Files / modules to know

Post-Sprint-6 architecture (everything since 2026-05-21):

- `ShhhcribbleiOS/Services/TextEngine.swift` — model + VAD + buffers + vocabulary + one-shot transcribe. Pure: takes buffers, returns text.
- `ShhhcribbleiOS/Services/AudioInput.swift` — mic + warm-engine + AirPods routing + interruption handler. Replaced AudioRecorder + AudioSessionManager + AudioInterruptionObserver.
- `ShhhcribbleiOS/Services/RecordingCoordinator.swift` — recording lifecycle + phase state machine + side-effects (SwiftData, clipboard, App Group). Owns the for-await loop. **Fix B's hoisted defer is here.**
- `ShhhcribbleiOS/Services/TranscriptionStatus.swift` — shared `@Observable` view-model. Kitchen-sink for SwiftUI bindings.
- `ShhhcribbleShared/KeyboardBridge.swift` — cross-process App Group bridge. Has the new `writeLiveAudioLevel` / `writeLivePartial` / `clearLiveStreams` methods from Sprint 8.
- `ShhhcribbleKeyboard/KeyboardRootView.swift` — the keyboard pill UI (`ShhhcribbleToolbar` + `ShhhcribblePill` + `CompilingProgressView`).
- `ShhhcribbleKeyboard/KeyboardViewController.swift` — keyboard lifecycle, polls App Group every 100ms while visible.

`CLAUDE.md` was updated to reflect the Sprint 6 architecture. Read it first too.

---

## Recent commits (most-recent first)

```
a86d310 Sprint 8 — Recording-state desync fix (A+B+C) + keyboard pill visual polish
ee24575 Sprint 8 WIP — Keyboard pill redesign (visual + live-data plumbing)
bc9de67 backlog: mark #4 (first-launch empty state) shipped
bba114a FB-4 — Model-state-aware empty state in NotesListView
b24349d backlog: mark #1 (keyboard CAPS) and #3 (FAB mic icon) shipped
3902585 FB-1 + FB-3 — Mic icon for play FAB; force KeyboardKit autocap reset
cb5c1d4 backlog: mark #6 (feedback flow redesign) shipped
363653d Sprint 7 Step 2 — Feedback UX redesign (backlog #6)
ca6214c Sprint 7 Step 1 — Feedback feature: refactor split (no UX change)
c4a7893 docs: update CLAUDE.md for Sprint 6 architecture
1beee3f Sprint 6 Step 3 — Promote TranscriptionService to RecordingCoordinator
dc0ed03 Sprint 6 Step 2 — Consolidate audio capture into AudioInput
011d92c Sprint 6 Step 1 — Extract TextEngine from TranscriptionService
```

Plus this session's polish commit (after this handoff is written, see `git log`).

---

*Picked up by: paste this file into the next chat. Then `backlog.md` for the open items. Then `CLAUDE.md` for the architecture rules.*
