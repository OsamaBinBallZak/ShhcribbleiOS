# Superwhisper iOS — reverse engineering notes

*Captured 2026-05-19 from the App Store IPA of Superwhisper v2.10.3 (bundle ID `com.superduper.superwhisper-ios`, team `XDP69BYUP9`) pulled via [ipatool](https://github.com/majd/ipatool). Updated late 2026-05-19 after `idevicesyslog` confirmed the actual wake mechanism live on device.*

## TL;DR — the actual architecture

Superwhisper's "tap mic in keyboard → speak → text inserted" UX rests on **two pillars** and an **optional accelerator**:

1. **Custom URL scheme open from keyboard extension.** Keyboard fires `extensionContext.open(superwhisper://keyboard)`. SpringBoard allows it via an internal "predates iOS 10.0" allowlist for `com.apple.keyboard-service` extensions. App launches, handles the URL, enters warm mode, starts recording. **This IS the cold-start mechanism.** ~250ms end-to-end.
2. **`UIBackgroundModes: push-to-talk` + `com.apple.developer.push-to-talk` entitlement** to extend background runtime so subsequent keyboard taps within the warm window stay inline (no app switch).
3. **Optional**: a user-installed Shortcut that wraps their `ToggleRecordingIntent` (an iOS 18+ AppIntent conforming to `AudioRecordingIntent`) — lets the user skip the app-switch entirely by firing `shortcuts://run-shortcut?name=...` from the keyboard instead. This is a UX accelerator presented in their first-cold-start flow ("install the shortcut to avoid this step in the future").

**What they explicitly DO NOT do** (debunked previous assumptions):
- **Do NOT link `PushToTalk.framework`.** `otool -L` returned 0 references. They have the entitlement, but no PTChannelManager code. PTT is declared for background runtime only.
- **Do NOT use APNs / a backend.** No `aps-environment` entitlement. No bundled networking framework beyond what iOS ships. Confirmed via entitlement dump + framework inspection.
- **Do NOT use AASA / Universal Links.** `superwhisper.com/.well-known/apple-app-site-association` returns 404. No `applinks:` entitlement. Their wake URL is the custom scheme.
- **Do NOT have any private entitlements.** Just App Group, Sign in with Apple, Push to Talk.

## The captured SpringBoard log (smoking gun)

From `idevicesyslog` running during a Superwhisper keyboard cold-start tap, 2026-05-19 11:58:09:

```
SpringBoard: Extension type "<com.apple.keyboard-service>" predates 10.0 
             — ignoring visibility check and allowing the openURL request.
SpringBoard: Allowing openURL request from extension 
             <xpcservice<com.superduper.superwhisper-ios.superwhisper-keyboard>>
             because it is visible (1) or entitled.
SpringBoard: Handling OpenURL from superwhisper-ke:4262: 
             url = superwhisper://keyboard
SpringBoard: Sending launch request: app<com.superduper.superwhisper-ios>
SpringBoard: -[SBApplication _processWillLaunch:] com.superduper.superwhisper-ios
```

**Two phrases matter:**
- *"predates 10.0 — ignoring visibility check"* — there's a legacy allowlist for keyboard-service extensions that bypasses the visibility check which normally blocks extension URL opens.
- *"because it is visible (1) or entitled"* — visible=1 means the keyboard is currently displayed to the user. Either visible OR entitled grants the open.

This is THE answer. Pure URL scheme. No magic.

## What's blocking us (the open question)

Our Development-signed build's `extensionContext.open(shhhcribble://keyboard)` returns `success=false` for the **same URL pattern, same Notes host, same iOS 26.4.2**. Either:

1. **Distribution-signing trust** — iOS treats App Store-signed apps differently for this allowlist. (Most likely. TestFlight build will verify.)
2. **A hidden distinction in entitlements** — though our codesign dump shows the same set as Superwhisper's. Unlikely.
3. **Some bundle structure difference** (Info.plist key, framework linkage, etc.). Unlikely after this much inspection.

---

## Raw findings — main app `com.superduper.superwhisper-ios`

### Entitlements (verified via `codesign -d --entitlements -`)

```
application-identifier:                XDP69BYUP9.com.superduper.superwhisper-ios
com.apple.developer.applesignin:       [Default]
com.apple.developer.push-to-talk:      true
com.apple.developer.team-identifier:   XDP69BYUP9
com.apple.security.application-groups: [group.superwhisper-keyboard]
```

That's the complete set. No `aps-environment`. No `applinks`. No private entitlements.

### Info.plist — load-bearing keys

```yaml
CFBundleURLTypes:
  - CFBundleURLName: com.superduper.superwhisper-ios
    CFBundleURLSchemes: [superwhisper]

UIBackgroundModes:
  - audio
  - fetch
  - processing
  - push-to-talk   # declared for background runtime; framework not used

BGTaskSchedulerPermittedIdentifiers: [com.superduper.superwhisper-ios]

NSSupportsLiveActivities: true
NSSupportsLiveActivitiesFrequentUpdates: true    # for waveform

NSUserActivityTypes: [StartRecordingIntentIntent]  # legacy SiriKit intent

UIApplicationShortcutItems:
  - { type: RecordAction, title: "Start recording", subtitle: "Turn your voice into text" }

LSSupportsOpeningDocumentsInPlace: true
UIFileSharingEnabled: true

LSApplicationCategoryType: public.app-category.productivity
LSRequiresIPhoneOS: true
MinimumOSVersion: 18.0
UIDeviceFamily: [1]
UIRequiredDeviceCapabilities: [arm64]   # NOT armv7
```

### Linked frameworks (verified via `otool -L superwhisper-ios`)

Bundled (`@rpath/...`):
- `ArgmaxSDK.framework` — WhisperKit's commercial wrapper (ASR backend)
- `KeyboardKit.framework` — same as us
- `LicenseKit.framework` — third-party license-key checking
- `Sentry.framework` — crash reporting (the only network-active component)
- `whisper.framework` — whisper.cpp likely

System frameworks worth noting:
- `AppIntents.framework` — for ToggleRecordingIntent + AppShortcuts
- `ActivityKit.framework` — Live Activity
- `StoreKit.framework` — in-app purchases / subscription
- `MetricKit.framework`
- `Network.framework` — standard iOS networking (used by Sentry for telemetry)

**Confirmed ABSENT:**
- `PushToTalk.framework` — **zero references**. They have the entitlement but don't use the framework.
- `BackgroundTasks.framework` — despite having `BGTaskSchedulerPermittedIdentifiers`, the framework isn't directly linked here (likely linked transitively via something else; not critical).

### `Metadata.appintents/extract.actionsdata` — the App Intents manifest

This file is generated by Xcode at build time from `@AppIntent`-marked Swift types. Their decoded contents:

```yaml
ToggleRecordingIntent:
  fullyQualifiedTypeName: superwhisper_ios.ToggleRecordingIntent
  title: "Toggle Recording"
  description: "Toggle a Superwhisper Recording"
  openAppWhenRun: false
  presentationStyle: 0
  systemProtocols:
    - com.apple.link.systemProtocol.AudioRecording       # AudioRecordingIntent (iOS 18+)
    - com.apple.link.systemProtocol.SessionStarting      # SessionStartingIntent
  parameters:
    - modeName: String (optional)
    - releaseMic: Bool (default false)
  outputType: String                                     # transcript

autoShortcutProviderMangledName: superwhisper_ios.SuperWhisperShortcuts

autoShortcuts:
  - actionIdentifier: ToggleRecordingIntent
    phraseTemplates: ["Toggle ${applicationName} Recording"]
    shortTitle: "Toggle Recording"
    systemImageName: record.circle
```

**One AppIntent.** Conforms to `AudioRecordingIntent` (allows the intent to record audio in the main app's process from background). The auto-shortcut registers in Shortcuts.app automatically. Users find it under "Toggle Superwhisper Recording."

---

## Raw findings — keyboard extension `superwhisper-keyboard`

### Entitlements

```
application-identifier:                XDP69BYUP9.com.superduper.superwhisper-ios.superwhisper-keyboard
com.apple.developer.team-identifier:   XDP69BYUP9
com.apple.security.application-groups: [group.superwhisper-keyboard]
```

**Identical structure to ours.** No special keyboard entitlements.

### Info.plist NSExtension block

```yaml
NSExtension:
  NSExtensionPointIdentifier: com.apple.keyboard-service
  NSExtensionPrincipalClass:  superwhisper_keyboard.KeyboardController
  NSExtensionAttributes:
    IsASCIICapable:    false
    PrefersRightToLeft: false
    PrimaryLanguage:   en-US
    RequestsOpenAccess: true                # same as us

NSMicrophoneUsageDescription: "Record audio for transcribing"
HostBundleIdentifier:         com.superduper.superwhisper-ios
URLScheme:                    superwhisper   # custom-key, internal lookup
UIRequiredDeviceCapabilities: [arm64]
MinimumOSVersion:             18.0
```

### Linked frameworks (verified via `otool -L`)

Standard set — Foundation, UIKit, SwiftUI, CoreFoundation, libobjc, NaturalLanguage, plus Swift's standard library. **No `PushToTalk.framework` in the keyboard either.**

The keyboard binary is **only ~370 KB** and contains ~568 strings — most of them encrypted under FairPlay. Logic is in the main app + KeyboardKit (linked from main app via `@rpath`). The keyboard is thin.

---

## Raw findings — auxiliary extensions

### `superwhisper-share.appex` — Share extension

Activation rule accepts `Audio` (max 1) and `File` (max 1). Lets the user share an audio file from any app into Superwhisper for transcription. Same App Group as the keyboard.

### `superwhisper-activity.appex` — full WidgetKit extension

`NSExtensionPointIdentifier = com.apple.widgetkit-extension`. It's a **full WidgetKit extension** (Live Activity + Home/Lock-screen widgets), not just a Live Activity. **No App Group entitlement** — Live Activity is display-only (read-only from main app's ActivityKit push). Same architecture as ours.

**Notable:** The widget extension ships its own copy of `ToggleRecordingIntent` (mangled name `superwhisper_activity.ToggleRecordingIntent`) — parameterless stub, no system protocol conformance. Lets a Live Activity button invoke the intent cross-process via the standard `LiveActivityIntent` pattern.

---

## Bundle contents we previously missed

Agent 3's deep dive surfaced things the initial inspection skipped:

### Bundled signed Shortcut

`/tmp/sw-ipa/Payload/superwhisper-ios.app/Toggle Superwhisper Dictation.shortcut` — a 23 KB Shortcuts-signed binary plist. Contains the action chain that wraps `ToggleRecording` AppIntent + `setclipboard`. Signed by Apple System Integration CA 4. **Superwhisper ships this pre-signed in the bundle**, so onboarding can deep-link `shortcuts://install-shortcut?...` and the install dialog doesn't require unsigned-shortcut approval from the user. This is what their "install the shortcut to avoid this step" flow does.

We should do the same: ship a pre-built `.shortcut` file, deep-link to install from onboarding.

### Audio cues

`start1.caf` and `end.caf` (~196 KB each) at the app bundle root. **Also duplicated inside the keyboard extension** at `PlugIns/superwhisper-keyboard.appex/`. The keyboard can play start/stop tones locally without main-app participation.

### Settings.bundle

`Payload/superwhisper-ios.app/Settings.bundle/Root.plist` is a single `PSGroupSpecifier` with footer text "To install the Superwhisper keyboard: 1. Select Keyboards / 2. Toggle on Superwhisper / 3. Toggle on Allow Full Access". No feature flags, just keyboard-install instructions inside iOS Settings → Superwhisper.

### swift-transformers + tokenizer configs

`swift-transformers_Hub.bundle` ships `gpt2_tokenizer_config.json` and `t5_tokenizer_config.json` — pre-tokenized config for GPT-2 BPE and T5 SentencePiece. Implies they do on-device post-processing or auxiliary model usage **beyond raw whisper.cpp**. Probably for the "Modes" feature — different prompt-formatting profiles run through small models.

### Persistence stack

`GRDB_GRDB.bundle` — they use GRDB (SQLite) for persistence, not SwiftData. Different choice from us; not blocking.

`swift-crypto_Crypto.bundle` — Apple's CryptoKit polyfill (for non-CryptoKit-platform support). Probably for license signing checks via LicenseKit.

### KeyboardKit version

`Frameworks/KeyboardKit.framework/` ships **182 `.lproj` localisation bundles** + an `Instructions.md` file. The free KeyboardKit doesn't ship this many locales or an instructions file. **Superwhisper is on the paid KeyboardKit Pro tier.** Our build uses free KeyboardKit. Mostly affects locales, autocorrect dictionaries, emoji picker, themes — none of which we need for Phase J Tier 2.

### `.storekit` in keyboard too

`PlugIns/superwhisper-keyboard.appex/superwhisper.storekit` — full StoreKit testing JSON duplicated into the keyboard. Implies LicenseKit / Pro-status check runs inside the keyboard process. Lets the keyboard know if the user has Pro without round-tripping the main app.

### `audiomxd` tracks their keyboard process

In our captured syslog, `audiomxd` (the audio-multi-extension daemon) tracks Superwhisper's keyboard XPC process even when it isn't actively recording. Unusual for a non-audio extension. Suggests iOS grants their keyboard audio-aware lifecycle treatment because the host app declares `audio` + `push-to-talk` background modes AND the keyboard requests Full Access.

If true: our keyboard, with the same setup, should get the same treatment. Worth verifying via our own keyboard's idevicesyslog.

---

## Update — what we got wrong in earlier drafts

- **The "Three pillars" framing in TL;DR earlier was wrong.** Updated above — the actual pillars are URL scheme + extended background runtime, with Shortcuts URL as an optional accelerator. AudioRecordingIntent is part of the Shortcut path but not the cold-start path.
- **PT framework was never "THE GATEKEEPER".** Superwhisper doesn't link the framework at all. The entitlement is for background runtime only.
- **The "Distribution signing trust" theory survived all agent reviews** as the most likely explanation for our `extensionContext.open` returning `success=false`.

---

## Cold-start UX flow, decoded from screenshots + log

User-observed sequence when warm mode is off ("cold"):
1. Tap keyboard mic → app foregrounds via `extensionContext.open(superwhisper://keyboard)` (verified in syslog).
2. App shows a screen: phone-icon graphic with orange dot, text "Superwhisper is on. Swipe to return to the keyboard. You can also install the shortcut to avoid this step in the future."
3. User swipes right (home indicator) → returns to Notes/Messages/whatever host they were in.
4. Recording continues in the warm app process.
5. User taps the mic again (in the keyboard, app stays backgrounded). The keyboard signals via App Group; the main app's foreground/background-polling task picks it up.
6. Recording stops, transcript is committed.
7. Transcript is written to App Group; keyboard reads + inserts via `UITextDocumentProxy`.

Subsequent recordings within the warm window stay inline — no app switch — until the warm timeout expires.

---

## Our delta — what we need to clone

### Tier 1 (works without Apple-approved entitlements, ships standalone)

| What | Done? | Where |
|---|---|---|
| `ToggleRecordingIntent` AppIntent | ✅ committed `dc68711` | `ShhhcribbleiOS/App/Intents/ToggleRecordingIntent.swift` |
| Conformance to `AudioRecordingIntent` system protocol | ❌ removed (caused SIGTRAP without PTT) — needs re-test now that PTT is in | same file |
| Register the intent in `AppShortcutsProvider` | ✅ committed `dc68711` | `ShhhcribbleiOS/App/Intents/ShhhcribbleShortcuts.swift` |
| Onboarding deep link to install the shortcut | ❌ pending | `OnboardingView.swift` |
| Add `processing` + `fetch` to UIBackgroundModes | ✅ committed `dc68711` | `project.yml` |
| BGTaskSchedulerPermittedIdentifiers | ✅ committed | `project.yml` |
| Remove `armv7` from UIRequiredDeviceCapabilities | ✅ committed | `project.yml` |
| `NSSupportsLiveActivitiesFrequentUpdates: true` (for waveform) | ❌ pending | `project.yml` |

### Tier 2 (Apple-approved entitlements granted 2026-05-19)

| What | Done? | Notes |
|---|---|---|
| `com.apple.developer.push-to-talk` entitlement | ✅ committed | Granted self-serve at developer.apple.com |
| `aps-environment: development` entitlement | ✅ committed | Required by PTT framework init even though we shouldn't need APNs |
| `push-to-talk` UIBackgroundMode | ✅ committed | Extends background runtime |
| `PushToTalkService.swift` linking `PushToTalk.framework` | ⚠️ unnecessary — Superwhisper doesn't link the framework; consider removing | We linked it to "use it for wake" before we realized PTT can't wake from cold without a backend, and Superwhisper doesn't try |
| PT channel joined → causes iOS "Talk" system bar to show | ❌ being torn down via `leaveChannelIfRestored()` | Built; awaiting user verification |
| `URLScheme: superwhisper` custom key in keyboard Info.plist | ❌ we use `KeyboardBridge.appOpenURL` constant instead; equivalent functionally | Not a behavioural diff |

### Tier 3 (the remaining unknown — Distribution signing)

| What | Done? | Notes |
|---|---|---|
| TestFlight build to verify if Distribution signing unlocks `extensionContext.open` | ❌ pending | The single unverified hypothesis for our cold-start failure |
| Live Activity with `NSSupportsLiveActivitiesFrequentUpdates: true` for the waveform | ❌ pending | UX polish, not blocking |
| `UIApplicationShortcutItems` 3D-touch quick action | ❌ pending | UX polish |
| `LSSupportsOpeningDocumentsInPlace: true` + share extension | ❌ pending | Out of scope for Sprint 5 |

---

## Reproducing the IPA dump

```bash
# Pull the IPA via ipatool (requires authenticated session)
ipatool auth login --email YOUR_APPLE_ID
mkdir -p /tmp/sw-ipa && cd /tmp/sw-ipa
ipatool download --bundle-identifier com.superduper.superwhisper-ios
unzip -q com.superduper.superwhisper-ios_*.ipa

cd Payload/superwhisper-ios.app

# Entitlements (works on FairPlay-encrypted binaries)
codesign -d --entitlements - .
codesign -d --entitlements - PlugIns/superwhisper-keyboard.appex
codesign -d --entitlements - PlugIns/superwhisper-share.appex
codesign -d --entitlements - PlugIns/superwhisper-activity.appex

# Linked frameworks (works on encrypted binaries)
otool -L superwhisper-ios
otool -L PlugIns/superwhisper-keyboard.appex/superwhisper-keyboard

# Info.plists (unencrypted)
plutil -p Info.plist
plutil -p PlugIns/superwhisper-keyboard.appex/Info.plist

# AppIntents metadata (unencrypted JSON)
cat Metadata.appintents/extract.actionsdata | python3 -m json.tool | less
```

## Reproducing the live-trace

```bash
brew install libimobiledevice
# Connect iPhone via USB; unlock + trust on first prompt
idevicepair pair
idevicesyslog -u <UDID> --no-colors -o /tmp/sw_syslog.log

# In another terminal, while idevicesyslog runs:
# 1. Force-quit Superwhisper on iPhone
# 2. Wait 30s
# 3. Open Notes, switch to Superwhisper keyboard, tap mic
# 4. Stop the capture (Ctrl+C)

# Then analyse
grep -iE 'superwhisper|com\.superduper|openURL|allowing|launching' /tmp/sw_syslog.log
```

## Key files referenced

- `/tmp/sw-ipa/Payload/superwhisper-ios.app/` — extracted IPA contents
- `/tmp/sw_full_syslog.log` — Superwhisper keyboard-tap idevicesyslog capture (1.1M lines, contains the SpringBoard "allowing openURL" entries quoted above)
- `/Users/tiurihartog/Hackerman/ShhcribbleiOS/.claude/worktrees/cool-chatterjee-c461d7/ShhhcribbleiOS/Services/PushToTalkService.swift` — our PT framework wrapper (probably unnecessary if Superwhisper proves you don't need to link the framework to benefit from the entitlement)
- `/Users/tiurihartog/Hackerman/ShhcribbleiOS/.claude/worktrees/cool-chatterjee-c461d7/ShhhcribbleShared/KeyboardBridge.swift` — `appOpenURL = shhhcribble://keyboard` constant, mirrors Superwhisper's pattern
- `/Users/tiurihartog/Hackerman/ShhcribbleiOS/.claude/worktrees/cool-chatterjee-c461d7/ShhhcribbleiOS/App/Intents/ToggleRecordingIntent.swift` — our equivalent intent (currently NOT conforming to `AudioRecordingIntent`; needs re-test now that PTT entitlement is in place)

## Open questions (for the auditing agents to answer)

1. Is there anything in Superwhisper's IPA we haven't extracted that would explain the `extensionContext.open` success vs ours failing? Specifically: their share extension's entitlements, the Activity extension's entitlements, anything in `SC_Info/Manifest.plist`, or anything in their `Metadata.appintents` we didn't decode.
2. Does our code wire up the `AudioRecordingIntent` conformance correctly now that PTT is in place? Should we re-enable it on `ToggleRecordingIntent`?
3. Is the PT system Talk bar actually leaving when we call `leaveChannelIfRestored()`, or do we need to remove `PushToTalkService` entirely?
4. What entitlement combinations DOES iOS look at when deciding the "predates iOS 10.0 keyboard-service" allowlist? Is there a documented or empirical signal for what we'd need beyond Distribution signing?
5. Are there iOS 26.x release notes or developer forum threads that mention changes to keyboard-extension URL-open behaviour we're missing?
