# Sprint 5 Handoff — Universal Links setup (Phase H)

*Last session ended 2026-05-18 with the decision to attempt Universal Links via GitHub Pages to bypass the iOS 26 "Open in app" confirmation prompt that's killing the keyboard's Voice button.*

If you're a fresh agent picking this up: **read SPRINT5_REPORT.md first** for the historical context. Then this file for the current state and your immediate task.

---

## What works today

- Hand-rolled QWERTY keyboard installs cleanly, appears in Settings → Keyboards, accepts typing in any text field. User has typed full sentences with it.
- In-app recording (play FAB) records and transcribes correctly.
- Lock-screen Live Activity Stop button commits without unlocking the phone.
- App Group, paid Developer Program signing, Darwin notifications + App Group polling are all wired and working.
- Warm mode (single-engine `AVAudioEngine` with silent player keeping the session active) was previously verified end-to-end before we switched to per-session mode.
- Settings → Keyboard has a duration picker (30s / 1 min / 5 min / Always). Default 1 minute.

## What's broken — the only remaining blocker

The **Voice button in the keyboard toolbar** can't open the containing app on iOS 26. iOS 26 added a confirmation prompt (`"Open in Shhhcribble?"`) before allowing custom URL scheme opens between apps. Keyboard extensions can't display that prompt, so `extensionContext.open(shhhcribble://record-from-keyboard)` silently returns `success=false`. We tried the responder-chain `openURL:` selector fallback — UIApplication accepts the selector at hop 10 but iOS silently drops the actual open.

**Confirmed:** SuperWhisper (the reference implementation) doesn't have a magic workaround — `curl https://superwhisper.com/.well-known/apple-app-site-association` returns 404, so they're not using Universal Links either. Their App Store reviews complain about the same screen-switching pain and they offer a Shortcuts-based workaround.

## The plan: Universal Links via GitHub Pages

Universal Links are HTTPS URLs registered to your app via an `apple-app-site-association` (AASA) file hosted on a domain you control. iOS treats them as web links, so **no confirmation prompt fires**. Once iOS has fetched the AASA at install (or shortly after), Universal Links work **fully offline** — iOS uses the cached AASA to decide which app to open. User asked this and the answer matters: yes, the mountain-cabin scenario works.

### Setup steps (in order)

#### 1. Create a GitHub Pages repo for the AASA file

The user has a personal GitHub. Easiest path:

- Create a new repo: `tiurihartog/shhhcribble-aasa` (or similar)
- Enable GitHub Pages in repo settings → source: `main` branch, root
- Create one file: `.well-known/apple-app-site-association` (NO `.json` extension)
- File contents:
  ```json
  {
    "applinks": {
      "details": [
        {
          "appIDs": ["9W82X49JZS.com.hendrivanniekerk.shhhcribble"],
          "components": [
            { "/": "/keyboard/*" }
          ]
        }
      ]
    }
  }
  ```
  Team ID `9W82X49JZS` is the user's paid Apple Developer Program team. Bundle ID is the main app's (NOT the keyboard's — Universal Links route to the containing app).

- Verify the file is served correctly: `curl -sSL -w "\n%{content_type}\n" https://tiurihartog.github.io/shhhcribble-aasa/.well-known/apple-app-site-association` — should return the JSON. Content-type may be `application/octet-stream` (GitHub Pages default) — Apple's CDN-validated path accepts this in practice. If it's served as HTML 404, the path is wrong; check that the file is named exactly `apple-app-site-association` with no extension.

#### 2. Add Associated Domains entitlement to the main app

Edit `project.yml` — the `ShhhcribbleiOS` target's entitlements `properties` block:

```yaml
    entitlements:
      path: ShhhcribbleiOS/ShhhcribbleiOS.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.shhhcribble.app
        com.apple.developer.associated-domains:
          - applinks:tiurihartog.github.io
```

(Use the exact domain from step 1. If you use a subpath like `tiurihartog.github.io/shhhcribble-aasa/keyboard/*`, the `applinks:` entry is just the bare host: `applinks:tiurihartog.github.io`.)

Also register the domain in the Apple Developer portal: developer.apple.com → Identifiers → `com.hendrivanniekerk.shhhcribble` → enable Associated Domains capability. May already be set after entitlement is in the build; verify via the portal.

Then `xcodegen generate` to regenerate `.xcodeproj`.

#### 3. Change `KeyboardBridge.recordURL` to the HTTPS URL

In `ShhhcribbleShared/KeyboardBridge.swift`:

```swift
public static let recordURL = URL(string: "https://tiurihartog.github.io/shhhcribble-aasa/keyboard/record-from-keyboard")!
```

(Keep the path stable — it's what the `components` block matches against.)

#### 4. Handle the Universal Link in the main app

The current URL handler in `ShhhcribbleiOS/App/ShhhcribbleApp.swift` is `.onOpenURL { url in handle(url: url) }` which handles custom URL schemes. Universal Links arrive via `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`. Add it alongside the existing onOpenURL:

```swift
.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
    guard let url = activity.webpageURL else { return }
    // Reuse the same path-matching logic. Universal links arrive as
    // https://tiurihartog.github.io/shhhcribble-aasa/keyboard/record-from-keyboard
    if url.path.hasSuffix("/record-from-keyboard") {
        if !AudioSessionManager.shared.warmModeActive {
            AudioSessionManager.shared.enterWarmMode()
        }
        startURLLaunchedRecording(trigger: .keyboard)
    }
}
```

#### 5. Test it

On device:
- Force-quit Shhhcribble
- Trigger a fresh install (`xcrun devicectl device install app …`)
- Wait ~10 seconds for iOS to fetch the AASA (it happens silently in the background)
- Launch Shhhcribble once to confirm it opens (no other action needed)
- Background, switch to Notes
- Tap the keyboard's Voice button

If the Voice button now opens Shhhcribble: **Universal Links from a keyboard extension work in iOS 26**. You've outdone SuperWhisper. Ship it.

If it still fails silently, see "If Universal Links don't work either" below.

### Common pitfalls

- **GitHub Pages serves AASA as `octet-stream`, not `application/json`.** Apple's docs say `application/json` is required, but in practice iOS accepts octet-stream. If validation fails, host on a domain with control over Content-Type (Cloudflare Workers, Vercel, your own server).
- **AASA cache.** Once iOS has fetched a 404 or invalid AASA, it caches that result for a while. Trigger a refresh: delete app, reinstall.
- **Team ID prefix.** The `appIDs` entry MUST be `<TEAM_ID>.<bundle_id>`. Wrong prefix = silent failure.
- **Personal Team vs Paid Program.** User is on paid (`9W82X49JZS`). Associated Domains works there. Personal Team has restrictions; not relevant for the user's setup.
- **Debugging AASA validation on device:** Settings → Developer → Universal Links → Diagnostics. (Developer menu only shows up if Xcode has been installed/connected at least once.)

## If Universal Links don't work either

Fall back to **Path B from the previous session's writeup**: tell the user to set the warm-mode duration to "Always" in Settings. They open Shhhcribble once after install, enable Always, accept the permanent orange mic indicator. From then on the keyboard's Voice button uses push-to-talk against the live engine — no app open needed.

This is what SuperWhisper users seem to be doing in practice. Ship-quality even if it's not the dream UX.

## Files you'll touch

- `project.yml` (Associated Domains entitlement)
- `ShhhcribbleiOS/ShhhcribbleiOS.entitlements` (regenerated by xcodegen)
- `ShhhcribbleShared/KeyboardBridge.swift` (change `recordURL`)
- `ShhhcribbleiOS/App/ShhhcribbleApp.swift` (add `.onContinueUserActivity`)
- New repo on GitHub for the AASA file

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

# Curl the AASA to verify hosting
curl -sSL -w "\n%{http_code} %{content_type}\n" \
  https://tiurihartog.github.io/shhhcribble-aasa/.well-known/apple-app-site-association

# Simulator (boot + install + open URL) — useful for verifying URL routing
xcrun simctl boot 7C38B713-D423-443D-A02E-18F600DBAAAB
xcrun simctl install booted /tmp/sb_simbuild/...ShhhcribbleiOS.app
xcrun simctl openurl booted "https://tiurihartog.github.io/shhhcribble-aasa/keyboard/record-from-keyboard"
```

The phone needs to be **unlocked** for `devicectl process launch` to succeed. If you see "Locked" errors, ask the user to unlock.

## Recent commits

Most recent: `ee1d3c1` — Phase E (session mode) + Phase G (hand-rolled QWERTY)

Before that:
- `8d47d52` — Sprint 5 polish (clipboard restore + warm-mode toggle + onboarding)
- `052ea71` — Sprint 5 working (single-engine warm + Task.cancel kill-switch)
- `5b8dc9d` — Sprint 5 status report (SPRINT5_REPORT.md)
- `2bb5673` — Investigation logs
- `0398e1c` — Initial keyboard scaffold
- `4295213` — Paid signing + App Group restored

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

Note: bundle prefix is still `com.hendrivanniekerk` (from when Hendri was the primary author). It works because the user's paid team can claim that namespace. Could be renamed to `com.tiurihartog.shhhcribble.*` in a future polish pass — not urgent.

---

*Hand off complete. Path A first; Path B is the safe fallback.*
