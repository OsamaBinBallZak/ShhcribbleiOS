# Sprint 5 / Phase J — handoff after the productive day

*Last updated 2026-05-20 evening. Cold-start works end-to-end. Read this file once at the start of a new session, then `backlog.md` for outstanding polish items.*

---

## TL;DR

**Cold-start from the keyboard works.** Tap the mic button in the Shhhcribble keyboard from any app, Shhhcribble foregrounds, recording starts, swipe right on the bottom bar to return to where you were, recording continues, transcript drops into the host text field when you stop. Same shape as Wispr Flow / Aqua Voice / Superwhisper.

Path B (warm-mode "Always" + in-keyboard PTT signal) still works as the no-app-switch alternative if a user prefers the orange-dot permanent-readiness UX.

`main` is still at `b1cb796` (pre-this-session). All of today's work lives on the branch `claude/laughing-hypatia-86b85c`, pushed to `origin` (Tiuri's personal GitHub repo `OsamaBinBallZak/ShhcribbleiOS`). When ready, merge that branch to main.

## How we got here today (compressed)

Yesterday's handoff claimed Wispr/Superwhisper used `extensionContext.open` from the keyboard, supported by a misread SpringBoard log. **That framing was wrong.** Three rounds of bundle-diff agents this morning all converged on `get-task-allow` as the cause — also wrong, refuted by Tiuri's empirical TestFlight test.

What actually worked: I built `KbSpike`, a 40-line minimum-spike iOS keyboard extension that does nothing but tap → `extensionContext.open(URL)`. Same failure as Shhhcribble. That proved the bug wasn't in our code or config — it was in the API itself. Web research then surfaced Apple DTS thread 65621 (Quinn the Eskimo, 2016 + 2024): `NSExtensionContext.open(_:completionHandler:)` is **documented Today-widget-only** and is statically refused by iOS inside the keyboard process. The `~200 µs synchronous false return without LaunchServices receipt` we saw is the diagnostic fingerprint of that refusal.

Working production voice keyboards (getdictus/dictus-ios, Joevonlong/Vowrite, TypeWhisper) all use SwiftUI's `openURL` action instead — either via captured `@Environment(\.openURL)` or `EnvironmentValues().openURL(url)` direct. Switching our keyboard's `openContainingApp(url:)` to that pattern fixed the cold-start in 4 lines.

The takeaway lesson logged in CLAUDE.md (Tier 4 working note): when an agent claims HIGH confidence, pressure-test against known empirical results before relaying it as a strong recommendation. The minimum-reproduction-spike is the fastest way to disambiguate "our code is broken" from "the API is broken" — should have been the first move yesterday, not the eighth.

## What shipped today (chronological)

| Commit | What |
|---|---|
| `2a67b20` | Phase J Tier 4 — cold-start unblocked via `EnvironmentValues().openURL` |
| `03c1fc2` | Tier 4b — migrate to captured `@Environment(\.openURL)` (Apple-blessed pattern) |
| `f625058` | Tier 5 — remove streaming ASR mode, keep only Parakeet TDT v3 |
| `1af94e8` | Tier 5.1 — kill live-transcript flicker via normalised-prefix snap |
| `c1a58e8` | Tier 6 Step A — load FluidAudio VAD alongside TDT |
| `19454b3` | Tier 6 Step B — feed audio buffers to VAD, log speech events |
| `49b26a3` | Tier 6 Step C — rotate buffer on VAD `speechEnd`, stitch chunks on stop |
| `955c047` | Tier 6 Step D+E — kill flicker re-introduced by VAD parallel work |
| `2bcc823` | Plan item 3 — "Waiting for audio device" banner (AirPods contention) |
| `fab173d` | Plan item 4 — swipe-back hint banner for keyboard cold-starts |
| `466f20c` | Plan items 5 + 6 — onboarding refresh + Full Access reset docs |
| `ef6e90c` | Backlog: SW-parity cold-start UX items |
| `79ba291` | Add in-app feedback capture (voice + screenshot + optional note) |
| _(unstaged)_ | Feedback UX iteration — toolbar split, append-on-tap, bulk email, zip attachment, post-send delete prompt |

## What works end-to-end now

- **Cold-start from keyboard** — verified on iPhone 13, iOS 26.4.2, Debug-signed and (likely) TestFlight Distribution-signed builds.
- **Long-recording crash fixed** — VAD-based chunk rotation keeps memory bounded. Verified with a 40-second monologue; rotation fired at the natural silence boundary; final transcript stitched committed chunks + final segment cleanly.
- **Live transcript no longer flickers** — four-case hybrid (strict prefix → append, normalised prefix → snap in place, small content rewind → honour, large rewind → reject with safety-valve unstick). Backlog has notes on future tuning ("Live-preview text stability strategy revisit").
- **AirPods contention banner** — shows when audio engine is up but no buffers are arriving (e.g. AirPods held by Mac via Continuity). Clears on first buffer.
- **Swipe-back hint** — when the recording was launched from the keyboard, the recording overlay shows a clear "Swipe right on the bottom bar to return" card with the iPhone-icon illustration.
- **Onboarding refresh** — KeyboardPage copy now matches the tap-once-to-record flow, with an "Open Keyboard Settings" deep-link button.
- **In-app feedback feature** — Settings → Feedback. Record voice + paste screenshot + optional note. Transcribed via TDT one-shot. Stored in `Documents/Feedback/<uuid>/{metadata.json, screenshot.png}` (accessible via Files.app since we enabled `UIFileSharingEnabled`). Multi-select + bulk email to `tiurihartog@icloud.com` with a `.zip` attachment of the raw folders for easy parsing. Post-send "Delete from device?" prompt.

## Known unresolved issues — full list in `backlog.md`

Headline ones:

- **First-record-after-install sometimes produces empty transcript** — TDT ANE warm-up. Workaround: force-quit + try again. Fix sketch in backlog (run synthetic-silence inference before flipping `model = .ready`).
- **Three Superwhisper-parity polish items** worth doing eventually: full-screen cold-start landing page, ship a `.shortcut` file for "skip the foreground dance via the Shortcuts app", and stop-button rotating animation + start/stop sounds.
- **Keyboard record button needs visual redesign** before the rotating animation lands (Tiuri's call).
- **Stashed work from today** (bigger SwipeBackHint card, `launchedFromKeyboard` swipe-back-stop fix, ModelLoadingBanner) — three untested changes that were reverted because the test environment didn't allow proper verification. Code in `git stash@{0}`. Re-attempt when there's bandwidth + internet to test on device.

## Doing a new TestFlight build

The mid-session CLI archive at `/tmp/sb_archive/Shhhcribble.xcarchive` was generated **before** the feedback-feature commit. For a fresh archive that includes the feedback UX work, use Xcode:

1. Open `ShhhcribbleiOS.xcodeproj`.
2. Select scheme `ShhhcribbleiOS`, destination "Any iOS Device (arm64)".
3. Product → Archive. Wait ~3 min.
4. Organizer opens automatically. Select the archive → **Distribute App** → App Store Connect → Upload.
5. Accept the defaults on subsequent screens (automatic signing, strip Swift symbols, upload symbols).
6. Wait 5–15 min for App Store Connect processing.
7. appstoreconnect.apple.com → My Apps → Shhhcribble → TestFlight tab → new build appears as `1.0.0 (2)`.
8. Tap it → fill "What to Test":
   > Major rebuild: keyboard cold-start now works (tap mic → app foregrounds → record → swipe right to return). Live transcript no longer flickers. Chunked transcription means long recordings won't crash. Single Parakeet TDT v3 engine (streaming mode removed). New "Feedback" section in Settings — record voice feedback about the app itself.
9. Export Compliance prompt: "No, my app uses only standard system encryption."
10. Add internal testers → submit.

`CFBundleVersion` was bumped from `1` to `2` in `project.yml` to make this upload accepted by App Store Connect (each build needs a unique build number within the same marketing version).

## Reviewing collected feedback later

Three paths, in order of preference:

1. **User emails it from their device** — tap "Send N" in the Feedback list → MFMailComposeViewController pre-filled with recipient `tiurihartog@icloud.com`, body containing the transcript summaries + device info, **and a `feedback.zip` attachment** containing the raw `metadata.json` + `screenshot.png` files. Extract the zip locally; iterate the subdirectories to read each item's structured JSON.
2. **Mac pull via `devicectl`** — when the user is on USB and unlocked:
   ```
   xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
     --domain-identifier com.hendritiuri.shhhcribble \
     --source /Documents/Feedback --destination ~/Desktop/feedback/
   ```
3. **Files.app on the iPhone** — Files → On My iPhone → Shhhcribble → Feedback. Enabled via `UIFileSharingEnabled = true` + `LSSupportsOpeningDocumentsInPlace = true` in Info.plist.

Each feedback item is a folder `<uuid>/` containing:
- `metadata.json` — `{ createdAt (ISO 8601), transcript, note, hasScreenshot, durationSeconds }`
- `screenshot.png` — present only when `hasScreenshot == true`

---

*See `backlog.md` for the prioritised list of remaining work.*
