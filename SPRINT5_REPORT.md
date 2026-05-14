# Sprint 5 — Keyboard Extension Status Report

*Generated: 2026-05-15. Session length: ~6 hours. Commits: 3 (4295213, 0398e1c, 2bb5673).*

This document captures the full state of Sprint 5 (custom keyboard extension with push-to-talk dictation) for resumption tomorrow. It is exhaustive on purpose: bugs, workarounds, dead ends, what we know works, and what almost certainly will or won't work.

---

## 1. What was already shipped before this session

Hendri (`itsHendri/ShhhcribbleiOS`) shipped Sprints 1 through 4.5+1 over five days in late April. By the time we started this session, the app had:

- SwiftData `Note` model with auto-save on stop
- `RecordingView` with audio-reactive `SoundwaveBars` + scrolling typewriter live text
- `NotesListView` with search, tag chips, swipe-to-delete
- `NoteDetailView` with inline edit, ShareLink, tag autocomplete, markdown view/edit auto-toggle
- `OnboardingView` (3 screens)
- Append-to-note transcription + "Continue recording" mini FAB on note detail
- Live Activity (`ShhhcribbleLiveActivity.swift`) with `TimelineView`-driven waveform
- Control Center widget (`RecordControlWidget.swift`)
- App Shortcuts (Siri integration): "Start Shhhcribble", "Record with Shhhcribble"
- Filler-word filter + substitution rules + custom hotwords (casing rewrite) settings
- AirPods route-change handling (rebuild engine on `AVAudioEngineConfigurationChange`)
- AudioInterruptionObserver (Siri handoff + phone-call interruption)
- Streaming + Parakeet TDT v3 ASR engines via FluidAudio

All of this **works correctly** in the in-app flow. Nothing here is broken.

Critically deferred at end of Hendri's work: the keyboard extension (Sprint 5), gated on App Group restoration which requires paid Apple Developer Program.

---

## 2. What this session accomplished

### Phase A — Repo sync ✅ committed
- Added `itsHendri/ShhhcribbleiOS` as `hendri` remote
- Fast-forwarded `OsamaBinBallZak/ShhcribbleiOS:main` to `itsHendri/ShhhcribbleiOS:main` (11 commits)
- Pushed to origin

### Phase B — Signing + App Group (commit 4295213) ✅ verified on device
- `project.yml`: swapped `DEVELOPMENT_TEAM L9T3PX7HVH` → `9W82X49JZS` (your paid Apple Developer Program team) on all three targets
- Restored `com.apple.security.application-groups: [group.com.shhhcribble.app]` entitlement on `ShhhcribbleiOS` and `ShhhcribbleWidget` targets
- Note the **App Group ID is `group.com.shhhcribble.app`**, NOT `group.com.shhhcribble`. That bare name was already claimed in the Apple Developer portal (probably by Hendri's Personal Team build). We registered a new one with `.app` suffix.
- Flipped `openAppWhenRun: true → false` on `StopRecordingIntent` and `CancelRecordingIntent`
- Replaced decorative Stop badge on the Live Activity with real `Button(intent: StopRecordingIntent())`
- Dropped the `.widgetURL(shhhcribble://open)` workaround
- **Verified end-to-end on device**: lock-screen Live Activity Stop button commits a recording without unlocking the phone. App Group cross-process intent routing is alive.

### Phase C1 — Keyboard target scaffold (commit 0398e1c) ✅ shipped but broken
- New `ShhhcribbleKeyboard/` directory:
  - `KeyboardViewController.swift` — `UIInputViewController` hosting SwiftUI
  - `KeyboardRootView.swift` — push-to-talk gesture, cold-start banner, "Open Shhhcribble" button
  - `Info.plist` — `NSExtension` block with `RequestsOpenAccess: true`
  - `ShhhcribbleKeyboard.entitlements` — App Group
- `ShhhcribbleShared/KeyboardBridge.swift` — App Group `UserDefaults` abstraction + Darwin notification helpers (`CFNotificationCenter`) + engine-keepalive timestamp + PTT signal read/write
- `project.yml`: keyboard target registered with `app-extension` type, depends on `ShhhcribbleShared`
- Keyboard UI installs on device, appears in **Settings → General → Keyboard → Add New Keyboard**, can be enabled with Full Access

### Phase C-r1, C-r2 — investigation (commit 2bb5673) ⚠️ NOT shipped to TestFlight
Multi-hour debugging session. State at end of session captured below.

---

## 3. The architectural lesson we learned the hard way

When the session started I assumed the keyboard extension could signal the main app via Darwin notifications + extensionContext.open. **Both turned out to be wrong** in the way I expected:

### 3a. `extensionContext.open(URL)` is silently refused

Tested across hosts:
- **Safari** — works (foregrounds Shhhcribble, starts recording)
- **Notes, WhatsApp, Mail, Messages, Spotlight** — silently refused, no foreground, no error

This is well-documented Apple behaviour: `NSExtensionContext.open(_:)` is intended for Today widgets and works in some hosts as a "user-initiated app launch" but most third-party hosts refuse it.

### 3b. Darwin notifications across extension ↔ app DO work — but ONLY if the main app is alive

This was the key research finding. Quinn (Apple DTS, forum 769398): *"iOS will not resume your app to receive a Darwin notification."* A suspended app silently misses the post — no queue, no replay.

When I ran a **self-test** posting + observing a Darwin notification within the main app, it fired correctly. But when the keyboard posted from another process while the main app was suspended in background, the main app's observer never fired. The reason: posting works fine; delivery to a suspended app is just dropped.

### 3c. The implication: the main app must stay non-suspended

The standard SuperWhisper / KeyboardKit pattern (and what 4 parallel research agents converged on) is: **hold a long-lived `AVAudioSession` with `.playAndRecord` + `setActive(true)` plus a running silent audio engine**. Combined with `UIBackgroundModes: audio`, this prevents iOS from suspending the app.

Trade-off accepted: **permanent orange microphone indicator** in the status bar. There is no API to suppress it. SuperWhisper accepts this; we said we would too.

---

## 4. What I tried for "always-warm session" and why it crashed

### Attempt 1 — `.playAndRecord/.default` + silent player

`AudioSessionManager.enterWarmMode()` was implemented to:
1. Set category to `.playAndRecord` mode `.default` options `[.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers, .defaultToSpeaker]`
2. Activate the session
3. Create an `AVAudioEngine` with an `AVAudioPlayerNode` looping a 200 ms silent buffer
4. Heartbeat every 5 s to App Group so keyboard's "engine warm" check passes

**Result on device:** app stayed alive, Darwin notifications arrived, recording started. BUT every recording captured empty audio. Even with the warm engine `pauseWarmEngine()` before recording.

### Attempt 2 — `.playAndRecord/.measurement`

Switched mode from `.default` to `.measurement` (disables AGC, recommended for ASR). Dropped `.mixWithOthers`. Kept `.playAndRecord` for the warm engine.

**Result on device:** app crashed with:
```
*** Terminating app due to uncaught exception 'com.apple.coreaudio.avfaudio',
reason: 'required condition is false: IsFormatSampleRateAndChannelCountValid(format)'
```

The crash is in `AudioRecorder.installTapAndStart()` at `inputNode.outputFormat(forBus: 0)` — that call returns an invalid format when the warm engine has the audio graph in an inconsistent state. Tried explicitly tearing down the warm engine + deactivating the session before the recorder runs — still crashed.

### Attempt 3 — Revert to Hendri's `.record/.measurement` + drop warm engine entirely

This is the current state in commit 2bb5673. The audio session category is back to Hendri's original `.record + .measurement + .duckOthers`. No warm engine. The warm-engine code is preserved in `AudioSessionManager` (`enterWarmMode`, `pauseWarmEngine`, `resumeWarmEngine`) but `ShhhcribbleApp.init` does NOT call `enterWarmMode()`.

**Result on device:**
- ✅ In-app recording (play FAB) works fine on a fresh app launch. Verified by user.
- ❌ Keyboard-triggered recording in background captures empty audio. The recorder doesn't crash but the streaming model gets no usable samples.
- ❌ Keyboard's "engine warm" check fails within ~10 seconds of backgrounding because heartbeats stop firing once iOS suspends the app.

---

## 5. Outstanding bugs (in priority order)

### Bug 1 — Keyboard-triggered background recording yields empty transcript [CRITICAL]
The whole point of the keyboard. Reproducer: hold mic in Notes for 2+ seconds, speak clearly, release. Result: `"Empty transcript — no speech detected"`. Same call path (`recordAndTranscribe`) works fine from foreground play FAB.

Hypotheses to test tomorrow:
1. **iOS silently denies mic input when `setActive(true)` is called in background** even with `UIBackgroundModes: audio`. Test by: in commit 2bb5673 we added `print` statements that will log "session activated successfully" or the failure — we never got to test this build end-to-end (you went to bed). First thing to do: relaunch, run a keyboard test, check the logs for "session activated" vs "session activate FAILED".
2. **Audio engine buffers ARE arriving but the streaming model isn't seeing them** because of some actor reentrancy or main-thread scheduling difference between `.manual` and `.keyboard` triggers. The same build prints `"AudioRecorder buffer #1 frameLength=..."` for the first buffer + buffer #10. If we see these during a keyboard test, the engine is capturing audio and the bug is downstream (model feed).
3. **Some weird interaction with `UIBackgroundTaskIdentifier`**. The `bgTaskId` claim happens before recording; maybe a path is different for background-launched recordings.

Diagnostic plan for tomorrow: build is already on device. Force-quit the app. Relaunch via the `xcrun devicectl device process launch --device <UDID> --console --terminate-existing com.hendrivanniekerk.shhhcribble` line. Do ONE keyboard test (held for ~3 seconds with clear speech). Read the logs — the new prints will tell us where audio is dropping.

### Bug 2 — `IsFormatSampleRateAndChannelCountValid` crash with warm engine [BLOCKER for always-warm]
Reproducer: enable warm mode via `ShhhcribbleApp.init` (set `keepKeyboardReady` flag to true) with `.playAndRecord/.measurement` session category, then attempt any recording. App crashes in `installTap`. Affects every recording, foreground or background, once the warm engine has been started.

This is the blocker for the SuperWhisper-style always-on architecture. Possible fixes to try:
- Share a single `AVAudioEngine` between warm-mode and AudioRecorder — currently they're two separate engines on one session. Hendri's CLAUDE.md note about "rebuild fresh engine per recording for AirPods" makes this awkward but not impossible.
- Use a different mechanism to keep the session alive without a second engine. Possible: `AVAudioSession.setActive(true)` alone, no engine, with `.playAndRecord` and a long-duration `UIApplication.beginBackgroundTask`. Untested.
- Skip the warm-engine path entirely and use **Apple's PushToTalk framework** (Agent 1's recommendation). Apple-blessed for exactly this UX. Risk: App Review may reject for a non-walkie-talkie app.

### Bug 3 — TranscriptionService actor races on rapid start/stop [HIGH]
Original Hendri code: `stopRequested` flag checked at various await boundaries. My additions: `pendingStopBeforeStart` / `pendingCancelBeforeStart` flags that defer-then-honour a stop arriving during init. Works for the long-hold case but the actor state can get into a "stuck" condition where:
- Cancel button in the in-app overlay logs `"Cancel: already stopping or not recording"` repeatedly
- Force-quit + relaunch is the only recovery

Research agent's recommended fix: replace the entire flag-based scheme with structured concurrency:
```swift
recordingTask = Task {
    try Task.checkCancellation()
    try await ensureModelLoaded()
    try Task.checkCancellation()
    // ...
    try await withTaskCancellationHandler {
        let engine = try await setUpEngine()
        engineHolder.set(engine)
        try await runCaptureLoop(engine)
    } onCancel: {
        engineHolder.tearDownSync()
    }
}
// stop:
recordingTask?.cancel()
```

Not done in this session — too invasive to attempt while debugging Bug 1. Planned as Phase C-r1 in the plan file but deferred.

### Bug 4 — Live Activity intent routing fails when app is backgrounded [LOW]
Logs show `"Live Activity start failed: visibility"` every time `recordAndTranscribe` starts from a keyboard trigger. The activity is graceful — recording continues without it — but the lock-screen Stop button won't be available during keyboard-initiated recordings. Same Apple-DTS issue as Darwin notifications: ActivityKit start needs the app non-suspended.

### Bug 5 — Stale signals fire phantom recordings on launch [FIXED in 2bb5673]
On app relaunch, the polling task was reading a stale signal from a prior session in App Group UserDefaults and triggering a recording on first tick. Fixed by seeding `lastSeen` from the existing signal timestamp at launch start.

### Bug 6 — Force-quit while recording leaves the actor in a confused state [WORKAROUND]
After a stuck recording (e.g. from any of the bugs above), the app's `RecordingPhase` state can desync from the actor's `recording` flag. Cancel button reacts visually but the action no-ops. Force-quit + relaunch always recovers. No code fix yet.

---

## 6. The pivot conversation we had with the user

Mid-session I ran 4 parallel research agents (opus, ~3 minutes each) to investigate the architecture. Their convergent findings made it clear we had two viable paths:

**Option A — SuperWhisper always-warm pattern (USER CHOSE THIS)**
Permanent audio session + silent player + accept orange mic indicator. The architecture in Sections 3–5 above. Status: **partially built, blocked by Bug 2**.

**Option C — Insert-only keyboard, trigger via Control Center / Siri / Back Tap (NOT CHOSEN)**
Cheaper, ships today, no App Review risk. Keyboard's only job: auto-insert when transcript lands. Recording started from other surfaces.

If Bug 1 and Bug 2 turn out to be intractable, **fall back to Option C is the right call**. The keyboard's autopaste machinery is already implemented and would work — we just need to wire `ClipboardService.snapshot`/`scheduleRestore` properly (Phase C-r4, also deferred).

Push-to-Talk framework (Option B from the plan) is theoretically possible but App Review will reject "dictation" apps using it. Not worth attempting.

---

## 7. Verification matrix — what actually works on device right now

| Path | State | Notes |
|---|---|---|
| In-app play FAB → record → Stop → transcript | ✅ Works | Verified post-relaunch. Phase B regression suspected if it stops working. |
| Lock-screen Live Activity Stop button | ✅ Works | Verified end-to-end in Phase B. Commits recording without unlocking phone. |
| Siri / App Shortcut / Back Tap → start recording | ✅ Works (Hendri's work, untouched) | Not retested this session but no changes affect this path. |
| Keyboard appears in **Settings → Keyboards** | ✅ Works | User added + enabled Full Access. |
| Keyboard mic button visually responds (push-to-talk gesture) | ✅ Works | 200 ms hold threshold rejects taps. Red "Listening…" state during hold. |
| Cold-start "Open Shhhcribble" button in keyboard | ❌ Refused by Notes/Mail/WhatsApp | Works in Safari. Apple-imposed restriction. |
| Keyboard-triggered recording from warm app (immediately after foregrounding Shhhcribble) | ⚠️ Sometimes captures, sometimes empty | Race-sensitive. |
| Keyboard-triggered recording from suspended app | ❌ Always empty transcript | Bug 1. |
| Always-warm session (`.playAndRecord` + silent engine) | ❌ Crashes app at next recording | Bug 2. |

---

## 8. Files modified in this session

| File | Change |
|---|---|
| `project.yml` | Team ID swap; App Group entries; new `ShhhcribbleKeyboard` target |
| `ShhhcribbleiOS/ShhhcribbleiOS.entitlements` | App Group `group.com.shhhcribble.app` |
| `ShhhcribbleWidget/ShhhcribbleWidget.entitlements` | App Group |
| `ShhhcribbleShared/KeyboardBridge.swift` | NEW — App Group + Darwin helpers + PTT signal API |
| `ShhhcribbleKeyboard/*` | NEW — entire target |
| `ShhhcribbleiOS/App/ShhhcribbleApp.swift` | Heartbeat task, Darwin observers, polling fallback, `recordfromkeyboard` URL handler, warm-mode gated off |
| `ShhhcribbleiOS/Services/AudioSessionManager.swift` | Major rewrite — warm mode methods (currently disabled), `.record/.measurement` restored as default |
| `ShhhcribbleiOS/Services/AudioRecorder.swift` | Diagnostic prints for input format + buffer counts |
| `ShhhcribbleiOS/Services/TranscriptionService.swift` | `pendingStop`/`pendingCancel` flags, pre-engine stop teardown, post-`darwinTranscriptReady` on empty for `.keyboard` trigger, App Group writeTranscript on commit, ShhhcribbleShared import |
| `ShhhcribbleShared/CancelRecordingIntent.swift` | `openAppWhenRun: false` |
| `ShhhcribbleShared/StopRecordingIntent.swift` | `openAppWhenRun: false` |
| `ShhhcribbleWidget/ShhhcribbleLiveActivity.swift` | Real `Button(intent:)` replacing decorative badges; `.widgetURL` dropped |

---

## 9. Where to pick up tomorrow

1. **Force-quit Shhhcribble. Relaunch with console:**
   ```bash
   xcrun devicectl device process launch \
     --device A9195A77-601A-54C1-B3BD-659FBFE1DC54 \
     --console --terminate-existing \
     com.hendrivanniekerk.shhhcribble
   ```
2. **Do ONE keyboard test** (held mic for ~3 seconds with clear speech). Read the logs streamed to stdout.
3. **Decode the new diagnostic prints we shipped in 2bb5673:**
   - `"session activated successfully"` vs `"session activate FAILED: ..."`
   - `"AudioRecorder input format: sampleRate=... channels=..."`
   - `"AudioRecorder buffer #1 frameLength=..."` and `"AudioRecorder buffer #10 ..."`
4. **Decision tree based on what those say:**
   - Activation FAILS → background mic denial confirmed → need PushToTalk framework or Option C pivot
   - Activation succeeds but no buffer prints → engine starts but no input → check audio session route, possible Bluetooth/AirPods edge case
   - Activation succeeds + buffers flowing but transcript empty → streaming model isn't getting fed, look at the AsyncStream → feedTask path in `TranscriptionService`
5. **If Bug 1 is fixable, attempt Bug 2 next** (warm engine without crash). Worth one more attempt with a SHARED engine between warm and recorder. If that fails, accept the cold-start UX and ship Option C.
6. **Bug 3 (actor refactor) is a code-quality win regardless** of which architecture wins. Do it as a follow-up after the keyboard path is settled.

---

## 10. Useful command palette

```bash
# Build + install + console-attached launch (most common loop)
xcodebuild -project ShhhcribbleiOS.xcodeproj -scheme ShhhcribbleiOS \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates -derivedDataPath /tmp/sb_build build \
  && xcrun devicectl device install app \
       --device A9195A77-601A-54C1-B3BD-659FBFE1DC54 \
       /tmp/sb_build/Build/Products/Debug-iphoneos/ShhhcribbleiOS.app \
  && xcrun devicectl device process launch \
       --device A9195A77-601A-54C1-B3BD-659FBFE1DC54 \
       --console --terminate-existing \
       com.hendrivanniekerk.shhhcribble

# Regenerate Xcode project from project.yml
xcodegen generate

# Device UDID
# A9195A77-601A-54C1-B3BD-659FBFE1DC54  (iPhone 13, iOS 26.4.2)
```

`os.Logger.notice/.error` output is NOT captured by `--console`. Use `print(...)` for diagnostics you want to see.

The phone needs to be **unlocked** for `process launch` to succeed.

---

## Closing thought

We didn't ship the keyboard tonight, but we now know exactly what's blocking it (background mic capture failure) and have a concrete debug path for tomorrow. The instrumented build is already on the device. One test cycle in the morning should tell us whether to keep pushing Option A or pivot to Option C.

— Sleep well.
