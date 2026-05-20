# Shhhcribble backlog

Features and refinements we've consciously deferred. Tracked here so they don't get lost in commit history. Newest at the top; cross out when shipped.

---

## Superwhisper-parity cold-start UX

Tiuri sent reference screenshots 2026-05-20. Three distinct pieces of polish to consider:

### 1. Full-screen cold-start landing page (vs our current small pill)

After tapping the keyboard mic, Superwhisper foregrounds with a dark full-screen takeover: phone-illustration with a finger pointing at the bottom bar, big text "Superwhisper is 🟠 on. Swipe to return to the keyboard.", plus a CTA underneath ("You can also install the shortcut to avoid this step in the future"). Way more visual + clear than our `SwipeBackHint` rectangle at the top of the existing recording overlay.

Could lift the existing recording overlay design with a new dedicated `ColdStartTakeover` view that renders ONLY when `launchedViaURL == true` AND `phase == .recording` AND there's no transcript yet — same illustration approach, swap in real `partialSnippet` once it starts arriving.

### 2. Ship a pre-made Shortcut to skip the cold-start dance entirely

Their bundle includes a `.shortcut` file (`Toggle Superwhisper Dictation.shortcut`) — a Shortcuts.app workflow that wraps their `Toggle Recording` AppIntent. Invoking the shortcut from anywhere (Back Tap, Action Button, widget) toggles recording WITHOUT foregrounding the app — bypasses the iOS-26.4 forced foreground entirely.

We already have `StartRecordingIntent` + `ToggleRecordingIntent` defined and registered. Users can build this in Shortcuts themselves today; the gap is discoverability + one-tap install.

To match SW: build a `Shhhcribble.shortcut` file in `Shortcuts.app` on Mac wrapping our `ToggleRecordingIntent`, export it, ship inside the app bundle, expose via deep-link button on the cold-start landing page ("Install the shortcut to skip this screen in the future"). The deep link URL is `shortcuts://import-shortcut?url=...&name=Shhhcribble`.

### 3. Stop-button animation + start/stop sound effects

Superwhisper's stop button has a rotating ring around it while recording — confirms visually that the recording is still live. They also play subtle start/end audio cues so the user knows when the recording has begun and ended (especially useful after the foreground dance, where the user is staring at their phone going "did it start?").

For us: small SF Symbol or shape animation around the Stop button in the recording overlay (rotating circle, pulsing ring, etc.), plus drop `start.caf` and `end.caf`-equivalent audio files in the bundle and play via `AVAudioPlayer` at the start/stop transitions. Both should respect the silent switch.

---

## First-record-after-install sometimes records but doesn't transcribe

**Symptom.** On the very first recording attempt after a fresh install (devicectl or TestFlight), the recording overlay shows the waveform animating (audio is being captured) but the live transcript stays empty / shows "Hello?" or similar near-noise output, and the saved note is empty or near-empty. Cancel, tap play again — works perfectly on second attempt.

Status row says "Model ready" before the first tap. So the user-facing readiness indicator says go, but TDT isn't actually warm enough yet to produce real text on the first inference call. Likely an ANE warm-up cost: the model is loaded but the first inference pass takes longer than a normal one (CoreML / Apple Neural Engine cold-start) and may produce degraded output if cut short.

Seen 2026-05-19 and 2026-05-20. Reproducible enough to mention to users as a workaround ("if the first recording doesn't work, force-quit and try again") but worth tracking for a real fix.

**Possible fixes (sketches, not researched):**

1. **Warm the TDT decoder on launch.** After `ensureModelLoaded()` completes, run a one-time synthetic-audio inference pass (e.g. transcribe 0.5 s of silence) so the ANE compute graph is fully primed before the user taps play. Adds ~100-500 ms to launch but invisible (happens behind onboarding / splash).

2. **Detect the failure mode and silently retry.** If the first finish returns empty or below a confidence threshold AND `lastRotationAt == nil` (first inference), re-run the transcribe on the same buffer. Slower than (1) for the user but doesn't depend on a clean warm-up path.

3. **Hold "Model ready" status until a warm-up inference completes.** Cleanest from a state-machine perspective — the readiness indicator stops lying. But means the user waits ~500 ms longer to see "Ready". Acceptable if the model-download progress ring extends to cover this phase too.

**When to revisit:** if the workaround "tap cancel then tap play again" stays annoying. Right now it's a documented one-time-per-install gotcha.

---

## Live-preview text stability strategy revisit

**Context.** During recording, `TypingViewModel` (`ShhhcribbleiOS/Features/Recording/RecordingView.swift`) currently uses a four-case hybrid (Tier 6 Step E.2, 2026-05-20): strict prefix → append; normalised prefix → snap in place; small content revision (≤15 char rewind) → honour the rewind; large content revision → reject, with a `rejectionLimit=4` safety valve that force-accepts the next update after 4 consecutive rejections (~2.8 s of staleness max).

We tried pure Option B (never rewind) first and it deadlocked — TDT was producing too many small word revisions that none extended the displayed text, freezing the live preview. The hybrid lets the small ones through fluidly and rejects only the catastrophic flips.

**Things to look into later, in rough priority order:**

1. **Word-level confidence freeze.** Track each word in the displayed text and how many consecutive live transcribes it survived unchanged. Words that have been stable for N=3 iterations get "frozen"; only the unstable tail gets revised. This would let small genuine corrections ("their" → "there") through while preventing wholesale flickers. Adds a tokenisation pass per update — cheap enough.

2. **Threshold rewind hybrid.** Allow a rewind if the resulting displayed text would still be ≥ 75% of the current displayed (i.e. the revision is "small"). Catches word corrections while blocking catastrophic flips. Simpler than (1).

3. **Forced unstick.** If the displayed text hasn't grown for >3 seconds AND the TDT live transcribes have been producing non-prefix output that whole time, accept the next update unconditionally. Prevents the rare "live preview frozen even though recording continues" edge case that (1) and (2) might also hit.

4. **VAD on its own actor.** Currently TranscriptionService is one big actor. Tier 6 Step D moved VAD work to fewer Task spawns but they still reenter the same actor, competing with TDT live transcribes. A dedicated `VADTracker` actor would fully decouple them. Might further smooth out live updates and let us re-enable Option A (legacy rewind for genuine revisions) without flicker.

**When to revisit:** if/when Tiuri starts noticing the live preview being noticeably stale during dictation. Right now we're prioritising stability.

---
