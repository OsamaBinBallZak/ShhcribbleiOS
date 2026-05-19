# Sprint 5 Handoff — Phase J Tier 2 done, paradigm shift on cold-start

*Last updated 2026-05-19 late evening. Three Opus agents + my own SDK diff have changed our understanding of the problem. This handoff is structured around what the next session needs to VALIDATE before acting.*

---

## How to use this handoff

Read this whole file before touching code. Most of what we believed at the start of today was wrong. The agents at the bottom of today produced strong evidence for a different mental model — but their findings are **claims to verify**, not facts. The next session's job is to validate the top claims with concrete experiments. Then implement.

You should port the validation results back to the operator (Tiuri) so they can confirm we're on the right track before committing to a deeper rewrite.

---

## What ships today (Path B — already working)

We have a **shippable product** as of `71e682e`. Path B works:

1. User installs Shhhcribble + enables the keyboard + grants Full Access.
2. User opens Shhhcribble, sets warm mode → "Always (mic indicator stays on)".
3. User backgrounds Shhhcribble. Orange dot stays in status bar.
4. User opens any text field in any app, switches to Shhhcribble keyboard.
5. User taps our small mic button at top-right of the keyboard.
6. Recording starts inline. User speaks. Taps stop.
7. Transcript inserts via `UITextDocumentProxy.insertText`.

**No app switch. Verified on iPhone 13, iOS 26.4.2, both Dev-signed and TestFlight Distribution-signed builds.**

Architecture:
- KeyboardKit free tier renders the keyboard.
- Our toolbar on top of KeyboardKit's `KeyboardView` has the mic button.
- Tap writes a "PTT" signal to App Group UserDefaults.
- Main app's polling task (alive during warm window) reads the signal → calls `TranscriptionService.recordAndTranscribe(trigger: .keyboard)`.
- On stop, transcript is written back to App Group + a Darwin notification fires.
- Keyboard's `textDidChange` and a 1-second poll both check for transcript ready → `insertText`.

Trade-off: orange mic indicator stays on permanently while warm mode is "Always". User chose this; competing apps avoid it via more complex paths we couldn't replicate.

## What's still missing (and why we spent today on it)

**Cold-start "tap mic from a suspended app" → app foregrounds + records.** This is the no-warm-mode UX where the user doesn't need to keep Shhhcribble running. Superwhisper, Wispr Flow, etc. all have some version of this. Our `extensionContext.open(_:completionHandler:)` from the keyboard returns `success=false`, blocking the app foreground.

We exhaustively matched Superwhisper's entitlements + Info.plist + AppIntent surface. Distribution signing tested. Cold-start STILL fails.

The latest Opus-agent research strongly suggests we've been chasing the wrong API.

---

## The paradigm shift (CLAIMS — to validate before acting)

Three Opus agents ran today: byte-level IPA diff, Apple Developer Forums research, social/community research. Their findings:

### Claim 1 — No third-party iOS keyboard actually uses `extensionContext.open`

**Sources:**
- Apple Developer Forums [thread 65621](https://developer.apple.com/forums/thread/65621) — Apple DTS engineer in 2016: *"`open(_:completionHandler:)` on NSExtensionContext is specifically documented for use on Today widgets only. ... If we wanted `open` to work in arbitrary extensions, we would not have gone out of our way to restrict it."* Comments still live through Jan 2025; no change to the API. **This is the most-cited primary source.**
- [KeyboardKit blog, Sep 2024](https://keyboardkit.com/blog/2024/09/11/ios18-breaks-selector-based-url-opening) by Daniel Saidi (KeyboardKit's author): iOS 18 killed the responder-chain `openURL:` hack with `"BUG IN CLIENT OF UIKIT"` log + force-return false. KeyboardKit's response was to render URL actions as SwiftUI `Link` views (user-tap, system-mediated, not programmatic).
- Wispr Flow's own "Adapting to iOS 26.4" docs explicitly confirm Apple changed app-switching behavior in iOS 26.4 — they migrated to a path that requires manual swipe-back. **They didn't break, they migrated.** Specifically to AppShortcut/AppIntent invocation.
- KeyboardKit issue [#903](https://github.com/KeyboardKit/KeyboardKit/issues/903) (open, May 2025) — a developer asking exactly our question, no resolution. Daniel Saidi hasn't answered. **The community-level "answer" is still in flux.**

**Implication:** the SpringBoard "predates 10.0" log line we captured from Superwhisper might NOT have been `extensionContext.open` succeeding. It might have been the system handling an AppIntent invocation that *looks* similar in the log. We may have misread the smoking gun.

**Validation task 1.A:**

Open a Mac → connect iPhone via USB → run `idevicesyslog -u 00008110-001208C902EA201E --no-colors -o /tmp/sw_validation.log`. While capturing, do exactly one Superwhisper cold-start keyboard tap. Then:

```bash
# Filter for the moment of activation, capturing ALL processes' activity in that window
sed -n '/Handling OpenURL/,/processWillLaunch/p' /tmp/sw_validation.log > /tmp/sw_window.log
# Look for intent identifiers (would indicate AppIntent path, not URL open)
grep -iE 'intent|IntentDonation|AppShortcut|LSActivate|BSAction|_intent|com.superduper.*Intent' /tmp/sw_window.log > /tmp/sw_intent_evidence.log
# Look for URL open evidence
grep -iE 'OpenURL|openURL|url = superwhisper' /tmp/sw_window.log > /tmp/sw_url_evidence.log
wc -l /tmp/sw_intent_evidence.log /tmp/sw_url_evidence.log
```

If `sw_intent_evidence.log` has more lines or earlier timestamps than `sw_url_evidence.log` → Wispr/Superwhisper are using AppIntent invocation, not URL open. Claim 1 confirmed.

If URL open is the only mechanism → Claim 1 partially refuted, dig deeper.

### Claim 2 — Wispr Flow uses AppShortcut / AppIntent invocation from the keyboard

**Sources:**
- Wispr Flow help docs: ["How to Set Up Flow Shortcuts for iPhone"](https://docs.wisprflow.ai/articles/1986921789-how-to-set-up-flow-shortcuts-for-iphone) — they call these "Flow Shortcuts" (literally AppShortcuts).
- ["Adapting to iOS 26.4"](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4) — confirms Apple changed how apps switch in iOS 26.4, users must manually swipe back.
- [9to5Mac coverage](https://9to5mac.com/2025/06/30/wispr-flow-is-an-ai-that-transcribes-what-you-say-right-from-the-iphone-keyboard/): *"Once you tap Start Flow from the app's third-party keyboard, it takes you to the full-blown Wispr Flow app, activates the Flow Session, and then hops you back to where you were."* — describes an Intent-mediated foregrounding, not a URL open.
- Apple Developer Forums [thread 751672](https://developer.apple.com/forums/thread/751672): `openAppWhenRun: true` works reliably when the AppIntent is defined in the main app target (multi-target source membership pattern).

**Concrete path to test (Path X):**

Our existing `StartRecordingIntent` in `ShhhcribbleiOS/App/Intents/StartRecordingIntent.swift` already has `openAppWhenRun: true`. It's compiled into both the main app and the widget target. Add it to the keyboard target.

Then in `ShhhcribbleKeyboard/KeyboardViewController.swift`, replace the `openContainingApp(url:)` call with:

```swift
private func handleVoiceTap() {
    // ... existing warm-path PTT signal code stays ...

    if !KeyboardBridge.isEngineWarm {
        // Replace `openContainingApp(url: appOpenURL)` with this:
        Task { @MainActor in
            do {
                try await StartRecordingIntent().perform()
            } catch {
                KeyboardBridge.debug("StartRecordingIntent.perform failed: \(error)")
            }
        }
    }
}
```

Then add the intent to the keyboard target in `project.yml`:

```yaml
  ShhhcribbleKeyboard:
    ...
    sources:
      - path: ShhhcribbleKeyboard
        excludes: ...
      - path: ShhhcribbleiOS/App/Intents/StartRecordingIntent.swift
      - path: ShhhcribbleiOS/App/Intents/StopRecordingIntent.swift
      - path: ShhhcribbleiOS/App/Intents/CancelRecordingIntent.swift
      - path: ShhhcribbleiOS/App/Intents/ToggleRecordingIntent.swift
```

(Same multi-target source membership pattern CLAUDE.md already documents for the widget target.)

`xcodegen generate` + build + install + test. Cold-start: tap keyboard mic with warm mode off. **Expected:** main app foregrounds and starts recording, just like Wispr Flow's documented UX. iOS 26.4 will require the user to manually swipe back, which is the same trade-off competitors accept.

**If this works** → Path X is the answer. Ship Phase J Tier 3 with this. Update the warm-mode "Always" toggle to be optional rather than required.

**If this fails** → AppIntent invocation from keyboard isn't the route either. Move to Claim 3.

### Claim 3 — Superwhisper records AVAudio IN THE KEYBOARD with Full Access

**Sources:**
- Apple Developer Forums [thread 742601](https://developer.apple.com/forums/thread/742601): "Recording audio in keyboard extension" — developer confirms with Full Access, AVAudioSession in the keyboard extension does work, contradicting common belief.
- Superwhisper's own site: *"hold to record, release to paste, with your words coming out as polished text in whatever app you're using"* — UX matches in-keyboard recording, not app foregrounding.
- [getvoibe.com Superwhisper review](https://www.getvoibe.com/resources/superwhisper-platform-support/): describes the limitations of the iOS keyboard experience consistent with in-extension recording.

**Why we couldn't see this directly:** Superwhisper's keyboard binary is only 370 KB (FairPlay-encrypted Mach-O), can't run `strings` on it usefully. We assumed the model lives in the main app and the keyboard couldn't record. **That assumption may have been wrong.**

**The catch for us:** our Parakeet TDT v3 ASR model is ~66 MB working memory. Keyboard extensions are capped at ~70 MB. If Superwhisper ships a smaller model (or runs WhisperKit Streaming differently in the keyboard), they fit. We might not.

**Validation task 3.A (cheap):**

In an isolated branch, write a minimal test in our keyboard extension:

```swift
// In KeyboardViewController.swift, add a test button that does:
let session = AVAudioSession.sharedInstance()
try session.setCategory(.record, mode: .measurement)
try session.setActive(true)
let recorder = try AVAudioRecorder(url: URL(fileURLWithPath: "/tmp/test.wav"), settings: [...])
recorder.record()
// 3 seconds later
recorder.stop()
// Read the file size and check we got audio
```

Build, install, grant Full Access, tap the test button. **Expected if Claim 3 is true:** audio file is non-zero, recording happened in the keyboard's process. We then need to figure out memory budget for an actual ASR model.

**If audio IS recorded in keyboard:** consider these architectures:
- **Architecture A (keyboard records, main app transcribes):** keyboard captures raw audio buffers, writes them to App Group as it goes, main app's warm engine transcribes. Requires warm mode but no app switch.
- **Architecture B (smaller ASR in keyboard):** use a smaller / streaming-mode ASR that fits in the 70 MB budget. No main-app dependency for transcription.

### Claim 4 — SDK version diff (small but verifiable)

**Source:** my own `otool -l` output.

```
Superwhisper main:   minos 18.0 / sdk 26.5
Our main:            minos 18.0 / sdk 26.2
Superwhisper kbd:    minos 18.0 / sdk 26.5
Our kbd:             minos 18.0 / sdk 26.2
```

iOS sometimes gates new behavior on linked-SDK version. Worth aligning to 26.5.

**Validation task 4.A:** in Xcode → Preferences → Components → check if iOS 26.5 Simulator / SDK is available. If yes, the Xcode itself might need updating. The user is on Xcode (whichever) with iOS 26.2 SDK; bringing in 26.5 may require Xcode 17.x latest beta or release.

```bash
xcodebuild -showsdks | grep iphoneos
```

**Then re-build + re-archive + re-upload** to TestFlight, retest cold-start with the new SDK. Probably doesn't fix the core issue but rules it out as a variable.

---

## Validation plan for the next session

In strict priority order. **Do them in sequence; stop at the first one that works.**

### Step 1 (15 min) — Re-capture Superwhisper syslog with more careful filtering (validates Claim 1)

The captured `/tmp/sw_full_syslog.log` from earlier shows `Handling OpenURL ... url = superwhisper://keyboard`. But Agent C noted this could be either:
- An actual `extensionContext.open` call (what we assumed)
- An AppIntent invocation that LSActivate routes via a URL-like internal handler (what Agent C suspects)

To disambiguate: capture a fresh syslog of a Superwhisper cold-start. Filter for `intent`, `LSActivate`, `BSAction`, `runningboardd.*Intent`, `AppShortcut` in the same time window as the URL-open log line. If those are present, the URL log is downstream of an intent invocation, not the cause of the launch.

The command to run is in Claim 1's "Validation task 1.A" above.

### Step 2 (30 min) — Implement Path X and test (validates Claim 2)

Path X is the cleanest hypothesis-driven experiment we can run. Code change is small (multi-target source membership + a 5-line keyboard handler change). Expected outcome is clear.

The full diff:

**`project.yml`** under `ShhhcribbleKeyboard:` → `sources:`:

```yaml
      - path: ShhhcribbleiOS/App/Intents/StartRecordingIntent.swift
      - path: ShhhcribbleiOS/App/Intents/StopRecordingIntent.swift
      - path: ShhhcribbleiOS/App/Intents/CancelRecordingIntent.swift
      - path: ShhhcribbleiOS/App/Intents/ToggleRecordingIntent.swift
```

**`ShhhcribbleKeyboard/KeyboardViewController.swift`** in `handleVoiceTap()` — replace the existing `openContainingApp(url: KeyboardBridge.appOpenURL)` line with the `Task { @MainActor in try await StartRecordingIntent().perform() }` block.

Then: `xcodegen generate` → `xcodebuild -project ShhhcribbleiOS.xcodeproj -scheme ShhhcribbleiOS -destination 'generic/platform=iOS' -configuration Debug -allowProvisioningUpdates -derivedDataPath /tmp/sb_build build`. Install. Test.

**Expected if Path X works:** keyboard mic tap (cold) → main app foregrounds (because `openAppWhenRun: true` on the intent type) → `StartRecordingIntent.performer` (wired in `ShhhcribbleApp.init` line ~50) fires → calls `recordAndTranscribe(trigger: .manual)` → recording starts. iOS 26.4 requires manual swipe-back to host app (same as Wispr Flow).

**If Path X fails** the user reports: "tap keyboard mic, nothing happens" OR "tap keyboard mic, app opens but no recording starts."

In either case, **DO NOT REVERT** before checking the log. Use:

```bash
xcrun devicectl device process launch --device A9195A77-601A-54C1-B3BD-659FBFE1DC54 --console --terminate-existing com.hendritiuri.shhhcribble
# Then have the user briefly foreground the app to flush keyboard drain logs
grep -iE 'kb |voice|perform|Intent' /private/tmp/claude-501/.../tasks/<task-id>.output
```

### Step 3 (60 min) — If Path X failed, validate Claim 3 (in-keyboard recording)

Add a minimal AVAudioSession + AVAudioRecorder test in the keyboard. See Validation task 3.A above for the snippet. If the keyboard CAN record, we have a whole new architecture to consider.

### Step 4 (30 min) — Align SDK version (validates Claim 4)

```bash
xcodebuild -showsdks | grep iphoneos
# If only 26.2 is available, check Xcode preferences for newer SDK install
# If 26.5 is available, build with it explicitly:
xcodebuild ... -sdk iphoneos26.5 ...
```

Re-archive + re-upload TestFlight + re-test. Probably doesn't fix things but worth ruling out.

### Step 5 — Apple DTS incident (1-7 days)

If Steps 1-4 didn't crack it: open a Technical Support Incident at https://developer.apple.com/contact/topic/select/ with the question Agent B drafted (it's in the agent's report — see `tasks/a19b636fc2eaa1d73.output` or the chat transcript). The exact question:

> "On iOS 26.4, calling `extensionContext.open(_:completionHandler:)` from a UIInputViewController keyboard extension synchronously in a button-tap handler returns success=false. The SpringBoard log for our bundle shows the openURL request being denied at the policy layer with no further detail, while a comparable App Store-distributed dictation keyboard (Superwhisper) succeeds, with SpringBoard logging 'Extension type "com.apple.keyboard-service" predates 10.0 — ignoring visibility check and allowing the openURL request' followed by 'Allowing openURL request from extension … because it is visible (1) or entitled.'
>
> 1. What are the precise conditions under which a keyboard extension is considered 'visible' by `BKSOpenApplicationService`?
> 2. Is `RequestsOpenAccess: true` + user-granted Full Access a prerequisite?
> 3. Is the 'entitled' path referring to a documented entitlement we can adopt?
> 4. Is the supported successor path an `AppIntent` with `openAppWhenRun: true`?"

---

## Verified facts (don't re-litigate these)

- **`extensionContext.open` from our keyboard returns `success=false`.** Tested under Dev signing + Distribution-signed TestFlight build, with PTT entitlement, with App Group, with Full Access, with multiple URL forms (custom scheme `shhhcribble://record-from-keyboard`, `shhhcribble://keyboard`, Universal Link HTTPS). Identical failure each time.
- **Our entitlements match Superwhisper exactly** (verified via `codesign -d --entitlements -`):
  - `application-identifier: 9W82X49JZS.com.hendritiuri.shhhcribble`
  - `com.apple.developer.push-to-talk: true`
  - `com.apple.developer.team-identifier: 9W82X49JZS`
  - `com.apple.security.application-groups: [group.com.shhhcribble.app]`
  - (Superwhisper additionally has `com.apple.developer.applesignin` which we don't need)
- **Our Info.plist matches Superwhisper exactly** for the keys we've verified: `UIBackgroundModes: [audio, fetch, processing, push-to-talk]`, `NSSupportsLiveActivities`, `NSSupportsLiveActivitiesFrequentUpdates`, `BGTaskSchedulerPermittedIdentifiers`, `NSUserActivityTypes`, URL scheme `shhhcribble://` registered correctly. Verified Stage 1: tapping the URL from Safari opens our app.
- **Our keyboard's `RequestsOpenAccess: true` is set in Info.plist.** Verified via `plutil -p`.
- **PushToTalk framework is NOT linked** in our binary (we removed `PushToTalkService.swift` after the audit). Superwhisper also doesn't link it (confirmed via `otool -L` returning 0 references). The entitlement alone is what extends background runtime.
- **Path B (warm mode "Always" + in-keyboard PTT signal) is working end-to-end** on both Dev-signed and TestFlight Distribution-signed builds. Verified with the user 2026-05-19.
- **No backend service is involved for either Superwhisper or us.** No `aps-environment` entitlement on either.
- **Distribution signing is NOT the variable.** Tested via TestFlight install (verified by user).

## Bundle IDs (after today's rename)

- Main app: `com.hendritiuri.shhhcribble`
- Widget: `com.hendritiuri.shhhcribble.widget`
- Keyboard: `com.hendritiuri.shhhcribble.keyboard`
- Shared framework: `com.hendritiuri.shhhcribble.shared`
- App Group: `group.com.shhhcribble.app` (unchanged by rename)
- URL scheme: `shhhcribble://`
- Team ID: `9W82X49JZS`

## Device

- iPhone 13, iOS 26.4.2
- UDID (devicectl): `A9195A77-601A-54C1-B3BD-659FBFE1DC54`
- UDID (libimobiledevice): `00008110-001208C902EA201E`
- TestFlight build 1.0.0(1) uploaded 2026-05-19 14:12 PT

## Sources to read directly (the next agent must)

These were difficult/impossible for Agents B and C to fully fetch from their sandboxes. Read them in a browser:

1. **[Apple Developer Forums thread 65621](https://developer.apple.com/forums/thread/65621)** — the canonical "extensionContext.open is for Today widgets only" thread. Comments through Jan 2025. CRITICAL.
2. **[Swift Forums thread 83988](https://forums.swift.org/t/how-do-voice-dictation-keyboard-apps-like-wispr-flow-return-users-to-the-previous-app-automatically/83988)** — community asking exactly our question, Jan 2026. May have new replies since Agent C's read.
3. **[Wispr Flow "Adapting to iOS 26.4"](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4)** — primary source on the iOS 26.4 behavior change.
4. **[KeyboardKit blog "iOS 18 breaks selector-based openURL"](https://keyboardkit.com/blog/2024/09/11/ios18-breaks-selector-based-url-opening)** — Daniel Saidi's analysis.
5. **[KeyboardKit issue #903](https://github.com/KeyboardKit/KeyboardKit/issues/903)** — open question on voice keyboard architecture.
6. **[Apple Developer Forums thread 742601](https://developer.apple.com/forums/thread/742601)** — Recording audio in keyboard extension with Full Access. May confirm the Path Y architecture.

## Recent commits (today's timeline)

```
71e682e Framework version fix for TestFlight + HANDOFF.md update
21946cf Bundle ID rename to com.hendritiuri.* + audit follow-ups M1/M3
1df51e4 Phase J Tier 2 final — full Superwhisper-parity config
dc68711 Phase J — Push to Talk entitlement + AppIntent foundation
7351409 Document Superwhisper iOS architecture from IPA reverse engineering
64f3191 Sprint 5 Phase H take 3 + warm-mode expiry bug fix
1d1ba2b Phase I — swap hand-rolled QWERTY for KeyboardKit free tier
85272d1 Sprint 5 Phase H — Universal Links empirically ruled out; Path B verified
```

## Agent transcripts (full reports from today's research)

If you need to re-read the full agent outputs:

- **Agent A (byte-level IPA diff):** `/private/tmp/claude-501/-Users-tiurihartog-Hackerman-ShhcribbleiOS--claude-worktrees-cool-chatterjee-c461d7/e041bedf-5275-4102-8a85-a2077ba851d5/tasks/a34216bc4cf177f6b.output` — was bash-blocked, only got partial findings; the SDK version diff I ran myself in the main thread (Superwhisper 26.5 vs ours 26.2).
- **Agent B (Apple Developer Forums):** `/private/tmp/claude-501/.../tasks/a19b636fc2eaa1d73.output` — produced the long-form report with the DTS thread 65621 + KeyboardKit blog references.
- **Agent C (social / community):** `/private/tmp/claude-501/.../tasks/a90e49e1c35e6ebcf.output` — produced the long-form report with the Wispr Flow / Superwhisper architecture analysis + "stop using extensionContext.open" conclusion.

## SUPERWHISPER_RE.md is also worth re-reading

It's been kept up to date through today's findings. Read it after this handoff.

---

## TL;DR for the next session

1. Run **Step 1 — re-capture Superwhisper syslog with intent-aware filtering**. If the SpringBoard launch came from an intent invocation rather than `extensionContext.open`, our entire today-investigation premise was wrong and the answer is Path X (AppIntent invocation).
2. **Implement Path X** (~30 min code change). Test cold-start. Report result.
3. If Path X works → ship it. If not → fall back to Path Y (in-keyboard recording test) or open Apple DTS.

Tell the operator the validation results and let them decide whether to keep going or call it.

— Sleep well.
