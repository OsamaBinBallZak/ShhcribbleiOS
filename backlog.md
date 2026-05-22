# Shhhcribble backlog

Features and refinements we've consciously deferred. Tracked here so they don't get lost in commit history. Newest at the top; cross out when shipped. Numbering is global across the whole file.

---

## AppIntent / shortcut audio-session investigation — 2026-05-22 (branch `claude/desync-cold-start-takeover`)

#22. **`ToggleRecordingIntent` can't claim background audio from Shortcuts.app or Control Center invocations.** Reproduced on iOS 26.4.2 with current `main` + the desync-cold-start-takeover branch. When the intent is invoked from Shortcuts.app or a Control Center "Shortcut" tile, iOS denies our AVAudioSession activation with `cm_session_begin_interruption error_code=-12985 "Operation denied. Cannot interrupt others"` because "in the background and not the NowPlaying app." Input format reads `2 ch, 0 Hz` → tap install would crash if not guarded.

Four research agents disagreed on the root cause. They DO converge once you read carefully:

- **Web research (most authoritative)**: `SessionStartingIntent` is NOT a public Swift protocol. The `com.apple.link.systemProtocol.SessionStarting` identifier in Superwhisper's `extract.actionsdata` is most likely **auto-emitted by conformance to a Live-Activity-family protocol** (`LiveActivityIntent` / `LiveActivityStartingIntent` / `AudioPlaybackIntent` — all public). These conformances also guarantee in-process execution per Apple's docs ([Zach Waugh's confirmation](https://zachwaugh.com/posts/forcing-appintent-to-run-in-main-app-process)). `AudioRecordingIntent` alone does NOT guarantee in-process routing — explains why our intent landed in the widget extension during Control Center tests until we removed it from the widget target's sources (this commit).
- **Apple's `AudioRecordingIntent` doc verbatim**: "you must start a Live Activity when you begin the audio recording and keep it active as long as you record audio. If you don't start a Live Activity, the audio recording stops." We currently start the Live Activity inside `RecordingCoordinator.performRecording` AFTER `perform()` returns — way past the privilege window.
- **Superwhisper IPA diff (empirical)**: Their `ToggleRecordingIntent`'s `extract.actionsdata` shows BOTH `systemProtocols: ["AudioRecording", "SessionStarting"]`. Ours has only `AudioRecording`. Every other Info.plist key, entitlement, UIBackgroundModes flag, and linked framework is identical between the two bundles. The single delta is a Swift-level protocol conformance that auto-emits the second identifier.

**The synthesized fix** (NOT YET ATTEMPTED — defer to a fresh session to re-verify the agent reasoning):

1. Add `LiveActivityIntent` (or `LiveActivityStartingIntent`) conformance to `ToggleRecordingIntent` alongside the existing `AudioRecordingIntent`.
2. Refactor `ToggleRecordingIntent.perform()` to do the audio-session-activation + Live-Activity-start **synchronously inside `perform()`** before returning. Current pattern (dispatch a `Task.detached` then sleep 200ms) loses the privilege grant the moment `perform()` returns.
3. Adjust `AudioInput.start()` to NOT re-activate the session if perform() already did — currently it calls `configure()` + `activateRetrying()` defensively, which would double-activate.

Once fixed: this also unblocks backlog #13 (.shortcut bundling). The shortcut on its own already works; what doesn't work yet is the intent-invocation-claiming-audio-from-background. Both ship together.

**Don't relitigate without fresh evidence.** Two of the four research agents reached the wrong conclusion on first pass (Agent 3 claimed `openAppWhenRun: true` was the only path — empirically falsified by Superwhisper's IPA showing `false`). Verify each piece on actual device before committing more code.

What's already shipped on the branch and IS working (verify with regression test):
- Recording-state desync race fix (the actual bug behind backlog #2 — not the band-aid)
- `launchedFromKeyboard` flag so swipe-back-to-keyboard doesn't terminate recording
- Cold-start takeover view (visible only when keyboard-launched + before first partial)
- `installPrivateEngine` crash guard (prevents SIGABRT on background-launch audio-format-invalid)
- Widget no longer compiles `ToggleRecordingIntent` (eliminates one wrong routing target)

The branch should NOT be merged to main until #22 is resolved AND the four items above are regression-tested on device. The shortcut path being broken is a known gap; the rest is improvements that shouldn't ship in isolation since the cold-start takeover is partially designed around the eventual shortcut flow.

Plan file for fresh session: `~/.claude/plans/lets-write-cached-turing.md`. Read that first, then this backlog entry, then start the LiveActivityIntent refactor.

---

## Keyboard pill redesign WIP — 2026-05-21

#20. **Gray space above the keyboard pill varies by host app (Tiuri).** Sprint 8 keyboard redesign shipped a 38pt grey pill but the keyboard surface area above the pill renders differently depending on which app is showing the keyboard:

- **WhatsApp**: gray wraps the pill tightly — ~4pt visible above, sides, and below. Looks correct.
- **Notes**: gray extends ~20pt above the pill before the pill starts. Looks wrong / wastes space.

Two attempts to fix from our side, both no-op on device:
- Attempt 1: `.padding(4)` all around the pill inside `ShhhcribbleToolbar`, remove the outer VStack's `.padding(.top, 4)`.
- Attempt 2: render `ShhhcribbleToolbar` inside KeyboardKit's `KeyboardView(toolbar: { _ in ... })` slot instead of in our own VStack.

**Diagnosis (2026-05-22):** the gray strip above the pill in Notes is iOS's own reserved space, NOT part of our keyboard view. Notes' rich-text editor declares `autocorrectionType = .yes` (and possibly `inlinePredictionType` on iOS 17+) which triggers iOS to reserve a "predictive text bar" inset above any custom keyboard. WhatsApp's chat input either has autocorrect off or uses a simpler input config that doesn't trigger the inset.

Since the inset is iOS-controlled and outside our keyboard's draw region, we can't shrink it from our side without breaking other text fields. **Three real options for future work:**

1. **Accept** (current decision). The pill is visually fine within its own region; the gray above is iOS's autocorrect-bar space, owned by the host app. Document and move on.
2. **Fill the strip with useful content** — render our own row INTO that space (something like predictive completions, or a live transcript overflow line during recording). Means we'd have to opt into autocorrect declaration on our keyboard side and implement candidate UI ourselves. Worth ~2 hours of investigation if/when we want to make Notes feel as clean as WhatsApp.
3. **Investigate Info.plist keys** like `PrefersTextInputContextIdentifier` or extension entitlements to opt OUT of the strip reservation. Risky and likely a dead end; Apple doesn't expose a documented way to refuse the autocorrect bar.

For now we accept. Picked up someday → option 2 most likely.

#21. **Auto-paste from keyboard mic + stop is broken (Tiuri, 2026-05-21).** Tied to FB-2 — the recording-state desync. When user taps the keyboard pill's mic button and the main app foregrounds with the broken overlay, they can't tap stop, so the transcript never gets to `commit()` and `KeyboardBridge.writeTranscript` never fires. Net result: no auto-paste. Will resolve when #2 is fixed.

---

## Architecture-split smoke-test observations — 2026-05-21

#19. **Music doesn't resume after recording stops (Tiuri).** Started music on the phone, tapped play FAB → music ducked → recording captured → after stop, music did not auto-resume. Root cause is pre-existing: warm mode keeps the AVAudioSession active for 60s after the last recording (default), so we never call `setActive(false, .notifyOthersOnDeactivation)` which is what tells the music app it can resume. Two options: (a) deactivate the session briefly between recordings even with warm mode on (might thrash the orange mic indicator), or (b) accept the trade-off and update onboarding to mention "music pauses while Shhhcribble is warm". Same behavior in the unrefactored code — not a Step 2 regression.

#18. **Live transcript flicker confirmed (Tiuri).** During an in-app dictation, Tiuri observed the displayed text "got rewritten" — went quite far, then everything disappeared and was quickly re-typed. Matches backlog #16 (live-preview text stability strategy revisit). Confirmed still present on Step 1+2 refactored code; same TypingViewModel four-case hybrid is in play. The waveform also "seemed to update very slow" relative to speech — possibly a separate observation about the SoundwaveBars history shift rate, or a side-effect of the same actor-saturation pattern that the hybrid was designed to mitigate.

#17. **Two record-y buttons on the NoteDetail screen are confusing (Tiuri).** When viewing an existing note, the bottom bar shows the new mini-mic "Continue recording" FAB next to the regular play FAB. Tiuri's reaction on first encounter: "I didn't know it was an option. Very cool to see. It is kind of confusing that there is then two buttons that do stuff." Worth revisiting the affordance — maybe one button with a contextual action (when viewing a note: append; otherwise: new), or visual differentiation that makes the relationship obvious. Original B3 design (CLAUDE.md, Sprint 4.5+1) replaced an inline note-body button with this mini-FAB because the inline one was "easy to miss when scrolled"; the new arrangement made it discoverable but at the cost of side-by-side confusion. Not urgent — append-to-note works correctly when found.

---

## Real-user feedback from first internal testing — 2026-05-21

Harry (harryhutton92@gmail.com — primary tester) and Tiuri sent 8 unique voice-feedback items via the new Feedback feature after the `1.0.0 (2)` TestFlight build. Raw zips at `/Users/tiurihartog/Hackerman/ShhcribbleiOS/feedback/extracted/` if anyone wants the original transcripts.

### 🔴 Bugs to fix soon

#1. ~~**Keyboard is always in CAPS (Tiuri).**~~ ✅ Shipped 2026-05-21. Root cause: `KeyboardSettings.isAutocapitalizationEnabled` (`@AppStorage` backed) had been persisted as `false`. KeyboardContext.init's `syncAutocapitalizationWithSetting` therefore set `autocapitalizationTypeOverride = .none`, hard-disabling all case changes. Fix: defensive reset of `keyboardCase = .auto` + `autocapitalizationTypeOverride = nil` + `isAutocapitalizationEnabled = true` in `viewWillSetupKeyboardView`, runs on every keyboard appearance so we self-heal from any future bad persisted state. Note Tiuri reported originally "all CAPS" but later reports said "all lowercase" — both are the same root cause, the autocap pipeline being hard-disabled, expressed differently depending on what previous shift state was persisted.

#2. **Recording-state get-stuck bug, recurring + persistent (Tiuri).** Mid-session in keyboard cold-start hits a state where: recording overlay is up, but Cancel and Copy/Save buttons don't respond to taps. Force-quit + reopen sometimes fixes it but the bug recurs immediately the moment the user re-triggers the keyboard mic. Related to but not identical to the existing "First-record-after-install" item — that one's about first-ever recording producing empty transcript; this one is about UI freezing mid-session.

**Latest reproduction 2026-05-21 (post-Sprint-6 split + keyboard pill redesign):**
- User in Notes app with Shhhcribble keyboard active
- Taps mic on the keyboard pill → app foregrounds via `shhhcribble://keyboard` cold-start URL
- Recording overlay appears in main app, BUT Cancel + Copy/Save buttons are inert
- User taps Cancel repeatedly → nothing happens
- User taps Copy/Save repeatedly → nothing happens
- User closes app, tries again → same bug fires immediately
- User keeps spamming the keyboard mic button → main app keeps "opening" but the broken overlay just keeps surfacing

**Console log capture from one of these reproductions** (truncated):
```
PTT signal: start at 2026-05-21 16:30:09 +0000
[kb 17:30:09.743] voiceButton.onTapGesture fired (idle mic)
[kb 17:30:09.746] voice tap: warm=false active=false
[kb 17:30:09.749] openContainingApp via captured @Environment(\.openURL) url=shhhcribble://keyboard
darwinStart received
Triggered
Stop: already stopping or not recording
Stop: already stopping or not recording
Stop: already stopping or not recording
```

The repeated "Stop: already stopping or not recording" means the user tapping Cancel/Stop is reaching `RecordingCoordinator.stopRecording()`, but the actor's `recording` flag is `false` — so the guard at the top fires and the call is a no-op. Meanwhile the overlay is still visible because `TranscriptionStatus.phase == .recording`. **The actor state and the UI state have desynced.**

Tiuri's diagnosis: "I want to audit the app a little bit, maybe improve code base architecture using the skill" — wants a focused investigation session. The Sprint 6 architectural split (RecordingCoordinator / TextEngine / AudioInput) didn't fix this — bug persists. Likely a race between `recording = true` being set inside `performRecording` and the keyboard's stop signal arriving via Darwin. The `pendingStopBeforeStart` plumbing was meant to handle this race but appears not to cover the case where recording NEVER actually starts (stuck in init).

**Likely root cause hypothesis:**
- `recordAndTranscribe` starts, sets `recording = true`, runs preflight (mic permission, etc.)
- Something fails or hangs in setup (`AudioInput.start` throws? `modelReady` blocks?), `recording` stays at `false` after the early-bail path, but the UI was already moved to `.recording` phase by `setUIRecording(true)` BEFORE the failure
- Now phase=.recording but actor recording=false → desync
- User taps Stop → guard fires → no-op

**To investigate next session:**
1. Reproduce on device with `--console` attached
2. Add diagnostic logging to every `recording = true/false` assignment + phase setPhase call so the desync moment is visible
3. Specifically watch what happens between "Triggered" log and the first "Stop: already stopping or not recording"
4. Hypothesis to test: `setUIRecording(true)` setting phase happens before `recording = true` propagates atomically, OR the `recording = false` gets reset by an early-return path that doesn't also reset phase

Likely fix once root cause is known: keep phase and `recording` flag updated atomically — either both via `setPhase`/`setUIRecording` together, or expose recording-state purely through `TranscriptionStatus.phase` and derive `RecordingCoordinator.recording` from it.

### 🟡 UX papercuts — clear wins, small lifts

#3. ~~**The play FAB icon (▶) is wrong (Harry).**~~ ✅ Shipped 2026-05-21. `play.fill` → `mic.fill` in `StartRecordingButton` (`ContentView.swift`). The "Record" label was considered but the FAB has no room for a label — icon-only stays compact, and the mic glyph is already universal.

#4. ~~**First-launch empty state is broken (Harry).**~~ ✅ Shipped 2026-05-21. New `NotesEmptyState` view reads `TranscriptionStatus.model` and adapts: `.loading` w/ downloadProgress → big ring with %, "Downloading transcription engine — 494 MB"; `.loading` w/ compileStep → single rotating arc whose length = step/total (currently /4) + current model name; `.ready` w/ no notes → "No notes yet / Tap the mic to start your first voice note" (matches FB-3 mic icon); `.error` → Retry button. The 25-second compile hang is now visible progress instead of a blank gear icon. Tiuri's deeper diagnosis (no indication anywhere of model state during first launch) directly addressed.

#5. **Keyboard recording UI lacks visual feedback (Harry).** Inside the keyboard, the recording state just shows "Recording" text + square stop button. No movement. Needs at minimum a fake animated waveform; ideally live transcript like Aqua Voice. Related to but more important than the existing "Stop-button animation + sounds" backlog entry — that's about the in-app overlay; Harry's pointing at the IN-KEYBOARD UI being static.

### 🟠 Feedback flow needs rework

#6. ~~**Feedback flow needs rework (Harry).**~~ ✅ Shipped 2026-05-21 (Sprint 7). Capture view: Cancel + Save replaced by demoted Discard + prominent Send; Send saves to disk and opens mail composer immediately. List view: green "Sent ✓" pill on rows that have been emailed; "Delete from device?" alert removed entirely; bulk-send + select-mode moved into a "…" menu so they don't compete with the primary "+" record-new button. Detail view: "Sent on <date>" banner + "Send again" button label for already-sent items. All four sub-complaints (a/b/c/d) addressed. Architecturally also resolved candidate #4 (FeedbackRecorder + FeedbackMailComposer extracted to their own files; FeedbackStore migrated to Codable + gained `sentAt: Date?` field and `markSent(_:)` method).

### 🟢 Onboarding polish

#7. **Keyboard activation should explain permissions inline (Harry).** Onboarding's KeyboardPage (post-Plan-item-5) has numbered steps + "Open Keyboard Settings" deep link, but Harry wants the permissions explained at each stage with more hand-holding. Particularly the Full Access toggle — what it does, why it's safe, what won't work without it.

#8. **"Enabling…" splash when user accepts keyboard from another app (Harry).** When user is in WhatsApp/Notes, taps Globe, then "Set Up New Keyboard" → picks Shhhcribble, ideally there's a flash overlay saying "Enabling Shhhcribble keyboard…" then auto-returns to WhatsApp with our keyboard's mic ready. Caveat: iOS owns the keyboard-picker flow; we can't insert a Shhhcribble screen there. What we CAN polish is the keyboard's first-load state — "Tap the mic to dictate" instead of just rendering empty.

---

## Stashed 2026-05-20 PM — three changes that were built but not verifiably tested

These were written in the afternoon session, never confirmed working, then reverted at Tiuri's request because the session had drifted into "build without verify" territory. Code lives in `git stash@{0}` ("Phase J Tier 6+ untested: bigger SwipeBackHint card, launchedFromKeyboard swipe-back-stop fix, ModelLoadingBanner."). Revisit individually when there's bandwidth + internet to test on device.

#9. **Bigger SwipeBackHint card with iPhone icon + orange dot.** Upgrade of the existing simple grey rectangle into a card-style layout: 44pt circle on the left with iPhone icon, then a small orange dot + "Shhhcribble is recording" headline, with the swipe instruction as secondary text below. Also includes an optional "Install shortcut" CTA underneath (hidden until we ship the `.shortcut` file).

Untested because the keyboard cold-start path needed the Full Access reset + re-enable, and the model wouldn't load (offline). Worth re-attempting on a stable testing setup.

#10. **`launchedFromKeyboard` flag to suppress auto-stop on swipe-back.** The scene-phase observer in `ShhhcribbleApp` auto-stops a launched-via-URL recording when the app goes to background. This is correct for Back-Tap / Shortcut launches ("tap back-pill = commit") but wrong for keyboard cold-starts where the user is supposed to swipe back to the keyboard while recording continues — directly contradicting our own swipe-back hint banner.

Fix sketch: add `launchedFromKeyboard: Bool` published on `TranscriptionStatus`. Set true in `handle(url:)`'s `case "keyboard"` / `"record-from-keyboard"`. Reset wherever `launchedViaURL` is reset. Scene-phase check becomes `phase == .background && status.isRecording && status.launchedViaURL && !status.launchedFromKeyboard`.

Untested because we couldn't reach the recording state without internet. Logic is straightforward; verify by: cold-start from keyboard, swipe right to return to host app, speak, return to Shhhcribble, confirm recording was still going.

#11. **`ModelLoadingBanner` in the recording overlay.** A spinner-banner shown when `status.model != .ready` while a recording is active. Tells the user audio is being captured while the model loads, so the empty live-transcript area doesn't look broken. Especially relevant for keyboard cold-starts where the user has no "model not ready" affordance to prevent the tap.

Copy adapts to state: download percentage during the download phase, "Preparing transcription engine — first launch can take ~25 s" during compile.

Untested because we were offline during the test attempt → the actual error case ("No internet connection. Parakeet TDT v3 needs a one-time download") rendered correctly in Settings → Status, but we never saw the loading banner mid-recording. Verify on a fresh install with internet.

---

## Superwhisper-parity cold-start UX

Tiuri sent reference screenshots 2026-05-20. Three distinct pieces of polish to consider:

#12. **Full-screen cold-start landing page (vs our current small pill).** After tapping the keyboard mic, Superwhisper foregrounds with a dark full-screen takeover: phone-illustration with a finger pointing at the bottom bar, big text "Superwhisper is 🟠 on. Swipe to return to the keyboard.", plus a CTA underneath ("You can also install the shortcut to avoid this step in the future"). Way more visual + clear than our `SwipeBackHint` rectangle at the top of the existing recording overlay.

Could lift the existing recording overlay design with a new dedicated `ColdStartTakeover` view that renders ONLY when `launchedViaURL == true` AND `phase == .recording` AND there's no transcript yet — same illustration approach, swap in real `partialSnippet` once it starts arriving.

#13. **Ship a pre-made Shortcut to skip the cold-start dance entirely.** Their bundle includes a `.shortcut` file (`Toggle Superwhisper Dictation.shortcut`) — a Shortcuts.app workflow that wraps their `Toggle Recording` AppIntent. Invoking the shortcut from anywhere (Back Tap, Action Button, widget) toggles recording WITHOUT foregrounding the app — bypasses the iOS-26.4 forced foreground entirely.

We already have `StartRecordingIntent` + `ToggleRecordingIntent` defined and registered. Users can build this in Shortcuts themselves today; the gap is discoverability + one-tap install.

To match SW: build a `Shhhcribble.shortcut` file in `Shortcuts.app` on Mac wrapping our `ToggleRecordingIntent`, export it, ship inside the app bundle, expose via deep-link button on the cold-start landing page ("Install the shortcut to skip this screen in the future"). The deep link URL is `shortcuts://import-shortcut?url=...&name=Shhhcribble`.

#14. **Stop-button animation + start/stop sound effects.** Superwhisper's stop button has a rotating ring around it while recording — confirms visually that the recording is still live. They also play subtle start/end audio cues so the user knows when the recording has begun and ended (especially useful after the foreground dance, where the user is staring at their phone going "did it start?").

For us: small SF Symbol or shape animation around the Stop button in the recording overlay (rotating circle, pulsing ring, etc.), plus drop `start.caf` and `end.caf`-equivalent audio files in the bundle and play via `AVAudioPlayer` at the start/stop transitions. Both should respect the silent switch.

---

#15. **First-record-after-install sometimes records but doesn't transcribe.**

**Symptom.** On the very first recording attempt after a fresh install (devicectl or TestFlight), the recording overlay shows the waveform animating (audio is being captured) but the live transcript stays empty / shows "Hello?" or similar near-noise output, and the saved note is empty or near-empty. Cancel, tap play again — works perfectly on second attempt.

Status row says "Model ready" before the first tap. So the user-facing readiness indicator says go, but TDT isn't actually warm enough yet to produce real text on the first inference call. Likely an ANE warm-up cost: the model is loaded but the first inference pass takes longer than a normal one (CoreML / Apple Neural Engine cold-start) and may produce degraded output if cut short.

Seen 2026-05-19 and 2026-05-20. Reproducible enough to mention to users as a workaround ("if the first recording doesn't work, force-quit and try again") but worth tracking for a real fix.

**Possible fixes (sketches, not researched):**

1. **Warm the TDT decoder on launch.** After `ensureModelLoaded()` completes, run a one-time synthetic-audio inference pass (e.g. transcribe 0.5 s of silence) so the ANE compute graph is fully primed before the user taps play. Adds ~100-500 ms to launch but invisible (happens behind onboarding / splash).

2. **Detect the failure mode and silently retry.** If the first finish returns empty or below a confidence threshold AND `lastRotationAt == nil` (first inference), re-run the transcribe on the same buffer. Slower than (1) for the user but doesn't depend on a clean warm-up path.

3. **Hold "Model ready" status until a warm-up inference completes.** Cleanest from a state-machine perspective — the readiness indicator stops lying. But means the user waits ~500 ms longer to see "Ready". Acceptable if the model-download progress ring extends to cover this phase too.

**When to revisit:** if the workaround "tap cancel then tap play again" stays annoying. Right now it's a documented one-time-per-install gotcha.

---

#16. **Live-preview text stability strategy revisit.**

**Context.** During recording, `TypingViewModel` (`ShhhcribbleiOS/Features/Recording/RecordingView.swift`) currently uses a four-case hybrid (Tier 6 Step E.2, 2026-05-20): strict prefix → append; normalised prefix → snap in place; small content revision (≤15 char rewind) → honour the rewind; large content revision → reject, with a `rejectionLimit=4` safety valve that force-accepts the next update after 4 consecutive rejections (~2.8 s of staleness max).

We tried pure Option B (never rewind) first and it deadlocked — TDT was producing too many small word revisions that none extended the displayed text, freezing the live preview. The hybrid lets the small ones through fluidly and rejects only the catastrophic flips.

**Things to look into later, in rough priority order:**

1. **Word-level confidence freeze.** Track each word in the displayed text and how many consecutive live transcribes it survived unchanged. Words that have been stable for N=3 iterations get "frozen"; only the unstable tail gets revised. This would let small genuine corrections ("their" → "there") through while preventing wholesale flickers. Adds a tokenisation pass per update — cheap enough.

2. **Threshold rewind hybrid.** Allow a rewind if the resulting displayed text would still be ≥ 75% of the current displayed (i.e. the revision is "small"). Catches word corrections while blocking catastrophic flips. Simpler than (1).

3. **Forced unstick.** If the displayed text hasn't grown for >3 seconds AND the TDT live transcribes have been producing non-prefix output that whole time, accept the next update unconditionally. Prevents the rare "live preview frozen even though recording continues" edge case that (1) and (2) might also hit.

4. **VAD on its own actor.** Currently TranscriptionService is one big actor. Tier 6 Step D moved VAD work to fewer Task spawns but they still reenter the same actor, competing with TDT live transcribes. A dedicated `VADTracker` actor would fully decouple them. Might further smooth out live updates and let us re-enable Option A (legacy rewind for genuine revisions) without flicker.

**When to revisit:** if/when Tiuri starts noticing the live preview being noticeably stale during dictation. Right now we're prioritising stability.

---
