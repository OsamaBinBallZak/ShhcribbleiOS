# Sprint 5 Handoff — Path B is the shipping path

*Updated 2026-05-18 after Phase H (Universal Links) was empirically ruled out and Path B (always-warm + orange mic) was verified end-to-end on device.*

If you're a fresh agent picking this up: **read SPRINT5_REPORT.md first** for the Sprint 5 historical context, then this file for current state.

---

## TL;DR

The keyboard's Voice button works **without an app switch** when the user sets Settings → "Keep keyboard ready for" → **"Always (mic indicator stays on)"**. Tap mic, speak, transcript appears in the host app's text field. Verified on iPhone 13, iOS 26.4.2, 2026-05-18.

Trade-off: a permanent orange mic indicator in the status bar (Apple's privacy badge for active audio sessions). This is the same trade-off no shipping iOS dictation keyboard has been willing to take — Wispr Flow, Superwhisper, and friends all accept the app-switch instead. Shhhcribble going the other way is a deliberate UX choice.

---

## What works today

- Hand-rolled QWERTY keyboard installs cleanly, appears in Settings → Keyboards, accepts typing in any text field.
- In-app recording (play FAB) records and transcribes correctly.
- Lock-screen Live Activity Stop button commits without unlocking the phone.
- App Group, paid Developer Program signing, Darwin notifications + App Group polling are all wired and working.
- **Always-warm mode + in-keyboard PTT verified end-to-end on device (2026-05-18).** Settings → Keyboard → "Always (mic indicator stays on)" → background app → open Notes → tap Voice button → speak → tap Stop → transcript inserts into Notes. No app switch.
- The codebase already has a single shared `AVAudioEngine` between warm-mode keepalive and `AudioRecorder` — SPRINT5_REPORT's Bug 2 (`IsFormatSampleRateAndChannelCountValid`) is resolved.

## What's broken — and why we can't fix it

The keyboard's cold-start path (when warm mode is OFF or expired) cannot reliably wake the containing app on iOS 26.4. We tried two transports and both fail:

- **Custom URL scheme** (`shhhcribble://record-from-keyboard` via `extensionContext.open`) — silently returns `success=false`. The responder-chain `openURL:` selector fallback also fails silently (UIKit-logged "BUG IN CLIENT OF UIKIT" since iOS 18; per KeyboardKit's writeup, definitively dead).
- **Universal Links** — see Phase H below.

Workarounds within iOS 26.4 are limited to:
1. Always-warm mode (Path B, shipping path).
2. App-switch UX (Path A, what every competitor ships).

---

## Phase H — Universal Links: empirically ruled out 2026-05-18

The theory: `extensionContext.open(HTTPS_URL)` from a keyboard would route via Universal Link instead of falling under the custom-scheme restriction, because iOS treats AASA-registered HTTPS URLs as web links.

We built it:
- Created `OsamaBinBallZak/shhhcribble-aasa` on GitHub Pages, hosting `.well-known/apple-app-site-association` (with `.nojekyll` so the dotfile dir is served).
- Added `com.apple.developer.associated-domains: applinks:osamabinballzak.github.io?mode=developer` to the main app entitlement.
- Added `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` handler in `ShhhcribbleApp.swift`.
- Pointed `KeyboardBridge.recordURL` at the HTTPS URL.
- Enabled Settings → Developer → Universal Links → Associated Domains Development (forces direct host fetch, bypassing Apple's CDN).

Result:
- `extensionContext.open(HTTPS URL)` from keyboard still returns `success=false` (logged on device).
- Tapping the same URL in Apple Notes opens **Safari**, not Shhhcribble — iOS does not register the AASA as Universal-Link-claimed despite developer mode.
- Apple's CDN (`app-site-association.cdn-apple.com/a/v1/osamabinballzak.github.io`) returns 404 for our domain. Apple's CDN learns about domains gradually as apps using them get installed. New domains may take days/weeks/never.

Phase H code has been reverted (commit baseline is `b1cb796`). The GitHub repo `OsamaBinBallZak/shhhcribble-aasa` and the `.well-known/apple-app-site-association` file are still up — harmless, costs nothing, leaves Phase H reproducible if Apple ever loosens the iOS 26 keyboard restriction.

**Don't re-investigate this path.** Two independent confirmations from research agents and one empirical device test all converged: keyboards cannot programmatically launch their container in iOS 26.4 regardless of URL scheme. Wispr Flow's iOS 26.4+ docs explicitly say "Apple requires Flow to briefly switch apps to activate the microphone."

---

## Path B (the shipping path) — how it works

Architecture, verified working:

1. App launches. If `warmModeAlways=true` in `@AppStorage`, `AudioSessionManager.shared.enterWarmMode()` runs in `ShhhcribbleApp.init`. This:
   - Sets `AVAudioSession.sharedInstance().category = .playAndRecord, mode = .measurement`.
   - Activates the session.
   - Spins up a single `AVAudioEngine` (`AudioSessionManager.warmEngine`) with an `AVAudioPlayerNode` looping a silent buffer attached to `mainMixerNode`. Volume = 0.
   - iOS now classifies the app as "active audio" → status bar orange mic indicator on, process protected from suspension.
2. While warm, a background task heartbeats `KeyboardBridge.heartbeat()` to App Group UserDefaults every 5s.
3. Keyboard extension reads `KeyboardBridge.isEngineWarm` (true if heartbeat < 12s old). When warm, its Voice button is accent-coloured ("Ready").
4. User taps Voice in keyboard. Keyboard writes `KeyboardBridge.writePTTSignal(.start)` to App Group UserDefaults.
5. Main app's `startKeyboardSignalPolling()` task (in `ShhhcribbleApp`) polls App Group every 100ms, sees the new signal, calls `TranscriptionService.shared.recordAndTranscribe(trigger: .keyboard)`.
6. Audio flows through the existing warm engine. `AudioRecorder` installs an input tap on `AudioSessionManager.shared.warmEngine.inputNode` (no second engine, no `setActive(true)` re-call — that's how Bug 2 was fixed).
7. User taps Stop in keyboard. Keyboard writes `KeyboardBridge.writePTTSignal(.stop)`. Main app stops recording, finalises transcript.
8. Main app writes transcript to `KeyboardBridge.writeTranscript(_:)` and posts the `darwinTranscriptReady` Darwin notification.
9. Keyboard's `consumeAndInsertTranscriptIfReady` reads + clears the transcript and calls `textDocumentProxy.insertText(transcript)`. Transcript appears in the host app's text field.

End-to-end with no app switch. Confirmed on iPhone 13, iOS 26.4.2.

## Path B — what's still missing before TestFlight

These are polish-level, not blockers:

- **Onboarding should explain the orange-mic trade-off.** Users will see a permanent orange dot in their status bar after enabling Always mode and probably wonder why. `OnboardingView` should have a screen specifically calling this out, with copy along the lines of "Shhhcribble keeps a low-power mic session alive so the keyboard can dictate instantly. iOS shows a tiny orange dot in your status bar while it's active — nothing is being recorded or transmitted, this is iOS's standard privacy indicator. You can turn this off in Settings if you want a manual mode."
- **The default should probably stay at "1 minute"** so first-time users don't get an unexplained orange mic before they've seen the explanation. After onboarding finishes (or in a dedicated onboarding step), prompt the user once: "Always (recommended): instant keyboard dictation, orange dot stays on" vs "Manual: tap to wake, no orange dot but one quick app open per session." Default to whatever they pick.
- **AirPods reconnect during always-warm mode** has not been explicitly tested. `AudioSessionManager.handleRouteChange` rebuilds the warm engine on `AVAudioEngineConfigurationChange`, which should self-heal, but verify with: enable Always, pop one AirPod out mid-typing, do a keyboard recording, confirm it still captures. If it fails, look at `AudioRecorder`'s 200 ms re-install delay at line ~152.
- **Phone call interruption.** `AudioInterruptionObserver` needs to call `AudioSessionManager.shared.reactivateAfterInterruption()` after `.ended`. Verify the wire-up — if missing, after a phone call the warm engine is dead and `isEngineWarm` goes false until the user reopens Shhhcribble.
- **Battery impact unknown.** Similar apps report ~1–5%/hr with always-warm. Worth a 1h benchmark before TestFlight to set user expectations.
- **Cold-start fallback when warm mode is OFF.** Currently broken on iOS 26.4 (no transport works). If a user picks 30s/1m/5m duration, the first dictation in a session opens the app via custom URL scheme — but the URL scheme is rejected by iOS 26.4. Two options: (a) hide the duration picker, ship Always-only with the orange mic; (b) keep the picker but be honest that 30s/1m/5m all require an app switch on the first dictation per session — and on iOS 26.4 the app switch never happens via URL scheme, so first dictation in a non-Always setting is currently silently broken. **Recommendation: hide the picker entirely, ship Always-only.**

---

## Recent commits

Most recent: `b1cb796` — Sprint 5 handoff prior to Phase H attempt.

Before that:
- `ee1d3c1` — Phase E (session mode) + Phase G (hand-rolled QWERTY)
- `8d47d52` — Sprint 5 polish (clipboard restore + warm-mode toggle + onboarding)
- `052ea71` — Sprint 5 working (single-engine warm + Task.cancel kill-switch)
- `5b8dc9d` — Sprint 5 status report (SPRINT5_REPORT.md)

This session's commit adds the Phase H rejection finding + Path B verification doc update only — no code changes (Phase H code was reverted).

---

## Useful commands

```bash
# Build for device
xcodebuild -project ShhhcribbleiOS.xcodeproj -scheme ShhhcribbleiOS \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates -derivedDataPath /tmp/sb_build build

# Install on device (UDID known)
xcrun devicectl device install app \
  --device A9195A77-601A-54C1-B3BD-659FBFE1DC54 \
  /tmp/sb_build/Build/Products/Debug-iphoneos/ShhhcribbleiOS.app

# Launch with console (only captures MAIN APP stdout — keyboard extension
# logs are routed via KeyboardBridge.debug into App Group and drained by
# the main app at runtime — see startKeyboardDebugLogDrain in ShhhcribbleApp.swift)
xcrun devicectl device process launch \
  --device A9195A77-601A-54C1-B3BD-659FBFE1DC54 \
  --console --terminate-existing \
  com.hendrivanniekerk.shhhcribble
```

The phone needs to be **unlocked** for `devicectl process launch` to succeed.

## Device info

- iPhone 13, iOS 26.4.2
- UDID: `A9195A77-601A-54C1-B3BD-659FBFE1DC54`
- Paid Apple Developer Program team ID: `9W82X49JZS`
- App Group: `group.com.shhhcribble.app`
- Bundle IDs:
  - Main app: `com.hendrivanniekerk.shhhcribble`
  - Widget: `com.hendrivanniekerk.shhhcribble.widget`
  - Keyboard: `com.hendrivanniekerk.shhhcribble.keyboard`
  - Shared framework: `com.hendrivanniekerk.shhhcribble.shared`

---

## Next session

Pick up with the Path B polish items above, in roughly this order:
1. Add onboarding screen explaining the orange-mic trade-off.
2. Hide the warm-mode duration picker; ship Always-only OR keep it but be explicit about the iOS 26.4 cold-start brokenness.
3. AirPods + phone-call interruption verification on device.
4. 1h battery benchmark in Always mode.
5. TestFlight.

Hand off complete. Path B works. Ship it.
