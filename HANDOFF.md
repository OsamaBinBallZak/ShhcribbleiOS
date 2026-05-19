# Sprint 5 Handoff — Phase J Tier 2 complete, cold-start mystery still open

*Updated 2026-05-19 evening after the TestFlight Distribution-signing test came back negative.*

If you're a fresh agent picking this up: **read SPRINT5_REPORT.md first** for Sprint 5 historical context, then SUPERWHISPER_RE.md for the architecture analysis, then this file for current state.

## TL;DR

**Path B ships today.** Warm-mode "Always" + in-keyboard PTT-style signal → recording works inline, no app switch. Verified end-to-end on iPhone 13, iOS 26.4.2, both Development and Distribution (TestFlight) signed builds.

**Cold-start (warm mode off, keyboard mic tap) still doesn't work.** `extensionContext.open(shhhcribble://keyboard)` returns `success=false` regardless of signing. Even after matching Superwhisper's entitlements + Info.plist + AppIntent surface byte-for-byte, our build's keyboard cannot wake the suspended main app — but Superwhisper's identical-looking keyboard does. There's a hidden factor we don't yet understand.

## What works today

- KeyboardKit-rendered Apple-style QWERTY (Phase I).
- Live Activity (with frequent-updates flag).
- In-app recording via play FAB.
- Warm-mode "Always" + Path B keyboard inline PTT: tap mic → speak → transcript inserts via UITextDocumentProxy. No app switch.
- AppIntent + Shortcut workflow (user installs the "Toggle Shhhcribble Recording" shortcut, then can invoke via Siri / Action Button / Shortcuts.app from anywhere).
- All entitlement + Info.plist + framework parity with Superwhisper.
- TestFlight build available for internal testers.

## What doesn't work

**Cold-start keyboard mic → app wake.** When warm mode is off (or has expired) and the user taps the mic in the keyboard:
- `extensionContext.open(shhhcribble://keyboard)` is invoked from the keyboard.
- iOS returns `success=false` to the completion handler.
- Nothing happens.

Superwhisper does the equivalent open and SpringBoard responds:
```
SpringBoard: Extension type "<com.apple.keyboard-service>" predates 10.0
             — ignoring visibility check and allowing the openURL request.
SpringBoard: Allowing openURL request from extension
             <xpcservice<com.superduper.superwhisper-ios.superwhisper-keyboard>>
             because it is visible (1) or entitled.
SpringBoard: Handling OpenURL from superwhisper-ke:4262 url = superwhisper://keyboard
SpringBoard: Sending launch request: app<com.superduper.superwhisper-ios>
```

(Captured via `idevicesyslog` in `/tmp/sw_full_syslog.log`, 2026-05-19 11:58:09.)

For our Distribution-signed TestFlight build, the equivalent SpringBoard log does NOT show the "Allowing openURL request" line — the open is being denied at a SpringBoard policy layer before it reaches our URL handler.

## What we've tried (full list)

### Confirmed dead-end
- Universal Links via AASA (`https://...`) — `extensionContext.open` from keyboard returns false regardless of valid AASA.
- Custom URL scheme `shhhcribble://record-from-keyboard` — same.
- Simplified URL `shhhcribble://keyboard` (matches Superwhisper exactly) — same.
- Responder-chain `openURL:` selector hack — broken since iOS 18.
- PushToTalk framework `PTChannelManager.requestBeginTransmitting` from main app's polling task — works when app is alive but doesn't wake from suspended without APNs backend.
- AudioRecordingIntent + Shortcuts URL bridge — works for the "user installed our shortcut" warm path, but iOS doesn't wake the main app from cold for the AppIntent invocation either.
- Development signing vs Distribution signing — IDENTICAL behaviour, ruled out as the variable.

### Verified working in our build
- Warm mode + PT entitlement + audio + push-to-talk background modes → keyboard mic inline works.
- `extensionContext.open` from Safari → app opens. So URL scheme registration is fine.
- TestFlight build install + Distribution-signed entitlements all correct.

### Open question
**WHY does Superwhisper's identical-entitlement keyboard succeed and ours fail?** Three deep-research efforts launched today + 2 already-completed audits couldn't identify the differentiator. Theories still on the table:

1. **A bundle resource or Info.plist key we missed** — IPA byte-diff agent should find it if so.
2. **iOS keyboard "trust" heuristic based on install age / usage history** — Superwhisper has been installed and used by millions; iOS may grant openURL allowlist progressively.
3. **A linked-SDK or build-flag difference** — our linked iOS SDK vs Superwhisper's (26.5).
4. **An iOS bug or undocumented heuristic** — Apple DTS may be the only way to resolve.

## Code state

Latest commit: `21946cf` Bundle ID rename to `com.hendritiuri.*` + audit follow-ups M1/M3
Plus uncommitted: framework MARKETING_VERSION fix (project.yml) for TestFlight upload.

Bundle IDs:
- Main app: `com.hendritiuri.shhhcribble`
- Widget: `com.hendritiuri.shhhcribble.widget`
- Keyboard: `com.hendritiuri.shhhcribble.keyboard`
- Shared framework: `com.hendritiuri.shhhcribble.shared`
- App Group: `group.com.shhhcribble.app` (not tied to bundle prefix)

Team ID: `9W82X49JZS` (paid Apple Developer Program).

Entitlements (main app):
- `com.apple.developer.push-to-talk: true`
- `com.apple.security.application-groups: [group.com.shhhcribble.app]`

Info.plist (main app):
- `UIBackgroundModes: [audio, fetch, processing, push-to-talk]`
- `NSSupportsLiveActivities: true`
- `NSSupportsLiveActivitiesFrequentUpdates: true`
- `BGTaskSchedulerPermittedIdentifiers: [com.hendritiuri.shhhcribble]`
- `NSUserActivityTypes: [ToggleRecordingIntentIntent]`

Bundles we don't have (and Superwhisper does — possible differentiators):
- `Toggle Superwhisper Dictation.shortcut` — bundled signed Shortcut file (deep-linkable for install)
- `start1.caf` / `end.caf` — audio cues
- Settings.bundle pane

## Research agents launched 2026-05-19 evening (pending)

1. **Byte-level IPA diff** — comparing our archive against `/tmp/sw-ipa/Payload/superwhisper-ios.app/`. Looking for any file content, Info.plist key, or framework detail we missed. Opus, background.

2. **Apple Developer Forums research** — searching threads from 2024-2026 for `extensionContext.open` returning false from keyboards on iOS 17/18/26. Opus, background.

3. **Community / social research** — X (Twitter), Indie iOS Dev Discord, Reddit r/iOSProgramming, Hacking with Swift forums. Looking for anyone who's solved this. Opus, background.

## What to do next session

If any of the 3 research agents found the answer:
- Patch the code, re-ship via TestFlight, re-test cold-start.

If none of them found the answer:
- Option A — **Open an Apple DTS incident.** Free with paid Developer Program (2 incidents/year). Apple engineers can see iOS internals. ~1-7 day turnaround. The most likely path to a definitive answer.
- Option B — **Ship Path B as the shipping UX.** Document the cold-start limitation in onboarding + nudge users toward "Always" mode. Match competitor behaviour (the user will see "swipe back to app" UX in Wispr Flow / Superwhisper anyway for a similar reason).

## Recent commits (Sprint 5 timeline)

```
21946cf Bundle ID rename to com.hendritiuri.* + audit follow-ups M1/M3
1df51e4 Phase J Tier 2 final — full Superwhisper-parity config
dc68711 Phase J — Push to Talk entitlement + AppIntent foundation
7351409 Document Superwhisper iOS architecture from IPA reverse engineering
64f3191 Sprint 5 Phase H take 3 + warm-mode expiry bug fix
1d1ba2b Phase I — swap hand-rolled QWERTY for KeyboardKit free tier
85272d1 Sprint 5 Phase H — Universal Links empirically ruled out; Path B verified
ee1d3c1 Sprint 5 — Phase E session mode + Phase G hand-rolled QWERTY keyboard
```

## Device info

- iPhone 13, iOS 26.4.2
- UDID (devicectl): `A9195A77-601A-54C1-B3BD-659FBFE1DC54`
- UDID (libimobiledevice): `00008110-001208C902EA201E`
- App Store Connect record: created with bundle `com.hendritiuri.shhhcribble`
- TestFlight build 1.0.0 (1) uploaded 2026-05-19 14:12 PT

## Useful commands

```bash
# Build for device (Debug, Development signing)
xcodebuild -project ShhhcribbleiOS.xcodeproj -scheme ShhhcribbleiOS \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates -derivedDataPath /tmp/sb_build build

# Install + launch with console
xcrun devicectl device install app \
  --device A9195A77-601A-54C1-B3BD-659FBFE1DC54 \
  /tmp/sb_build/Build/Products/Debug-iphoneos/ShhhcribbleiOS.app
xcrun devicectl device process launch \
  --device A9195A77-601A-54C1-B3BD-659FBFE1DC54 \
  --console --terminate-existing \
  com.hendritiuri.shhhcribble

# Full iOS system log via libimobiledevice (USB required)
idevicesyslog -u 00008110-001208C902EA201E --no-colors -o /tmp/sh_syslog.log

# Archive Release for TestFlight
xcodebuild archive \
  -project ShhhcribbleiOS.xcodeproj -scheme ShhhcribbleiOS \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath /tmp/sb_archive.xcarchive -allowProvisioningUpdates

# Compare against Superwhisper IPA
ls /tmp/sw-ipa/Payload/superwhisper-ios.app/
```

---

*Phase J Tier 2 complete. Path B is shippable. Cold-start unlock remains open.*
