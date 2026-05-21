# Shhhcribble backlog

Features and refinements we've consciously deferred. Tracked here so they don't get lost in commit history. Newest at the top; cross out when shipped. Numbering is global across the whole file.

---

## Architecture-split smoke-test observations — 2026-05-21

#17. **Two record-y buttons on the NoteDetail screen are confusing (Tiuri).** When viewing an existing note, the bottom bar shows the new mini-mic "Continue recording" FAB next to the regular play FAB. Tiuri's reaction on first encounter: "I didn't know it was an option. Very cool to see. It is kind of confusing that there is then two buttons that do stuff." Worth revisiting the affordance — maybe one button with a contextual action (when viewing a note: append; otherwise: new), or visual differentiation that makes the relationship obvious. Original B3 design (CLAUDE.md, Sprint 4.5+1) replaced an inline note-body button with this mini-FAB because the inline one was "easy to miss when scrolled"; the new arrangement made it discoverable but at the cost of side-by-side confusion. Not urgent — append-to-note works correctly when found.

---

## Real-user feedback from first internal testing — 2026-05-21

Harry (harryhutton92@gmail.com — primary tester) and Tiuri sent 8 unique voice-feedback items via the new Feedback feature after the `1.0.0 (2)` TestFlight build. Raw zips at `/Users/tiurihartog/Hackerman/ShhcribbleiOS/feedback/extracted/` if anyone wants the original transcripts.

### 🔴 Bugs to fix soon

#1. **Keyboard is always in CAPS (Tiuri).** The Shhhcribble keyboard's letter keys are all uppercase. Almost certainly a KeyboardKit default override — needs `shiftState` config or similar on the `KeyboardView`. Tiuri also said "we need to fix the keyboard anyway, so that's probably part of that, right?" — implies a broader keyboard visual redesign is desired alongside this.

#2. **Recording-state get-stuck bug, recurring (Tiuri).** Mid-session in keyboard cold-start sometimes hits a state where: recording UI is up, waveform shows, but no text appears and Cancel/Save buttons don't respond. Force-quit + reopen sometimes fixes it. Related to but not identical to the existing "First-record-after-install" item — that one's about first-ever recording producing empty transcript; this one is about UI freezing mid-session.

Tiuri's diagnosis: "I want to audit the app a little bit, maybe improve code base architecture using the skill" — wants a focused investigation session. Probably involves running the app under `--console` and capturing the actor state when the freeze happens.

### 🟡 UX papercuts — clear wins, small lifts

#3. **The play FAB icon (▶) is wrong (Harry).** Triangle reads as "play something that exists" — confusing for recording. Should be a mic icon, ideally with "Record" label. ~5 min change in `ContentView.swift`'s `StartRecordingButton`.

#4. **First-launch empty state is broken (Harry).** Opens app → empty state says "press play to listen to a transcript" (we don't actually have that copy literally, but this is what it feels like). User has no idea what to do. Empty state needs a big explicit "Tap the mic to start your first dictation" with an arrow/pointer to the FAB. Harry: "I'm just gonna tap the screen — it's like this didn't fucking do anything. Piece of shit app, uninstall."

#5. **Keyboard recording UI lacks visual feedback (Harry).** Inside the keyboard, the recording state just shows "Recording" text + square stop button. No movement. Needs at minimum a fake animated waveform; ideally live transcript like Aqua Voice. Related to but more important than the existing "Stop-button animation + sounds" backlog entry — that's about the in-app overlay; Harry's pointing at the IN-KEYBOARD UI being static.

### 🟠 Feedback flow needs rework

#6. **Feedback flow needs rework (Harry).** Harry made a coherent UX case against the current design. Four sub-issues:

a) **The "save locally → maybe send later" workflow is weird.** Default should be "record → review → send". Saving without sending defeats the purpose.

b) **Easy to close the feedback modal without sending.** Cancel button is symmetrically prominent with Save. Harry was confused about what saved without sending even meant.

c) **The "delete after send" prompt is wrong.** He wants to *keep* track of what he's told us. Deleting just because it was sent is anti-feature.

d) **No status indicator for "this has been sent" vs "not yet".** Items just sit in the list with no visible state.

Proposed redesign: on Save in `FeedbackCaptureView`, auto-stage for send (mail composer opens immediately). After successful send, the item gets a **"Sent ✓" badge** in the list. Items aren't deleted unless the user explicitly deletes them. Bulk-send + select-mode become optional power features, not the default flow.

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
