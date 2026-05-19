import AppIntents
import ShhhcribbleShared

/// The "no app switch" recording intent. Phase J Tier 1 (2026-05-19).
///
/// Conforms to `AudioRecordingIntent` (iOS 18+) — the sanctioned system
/// protocol for an AppIntent that needs background mic access. With
/// `openAppWhenRun: false`, iOS runs `perform()` in the main app's
/// process WITHOUT foregrounding it, leaving the host app (Notes,
/// Messages, etc.) on screen.
///
/// Mirrors Superwhisper's `ToggleRecordingIntent` (verified via IPA RE —
/// see SUPERWHISPER_RE.md). Their intent + ours are designed to be
/// invoked TWICE per dictation: first tap starts recording (returns ""),
/// second tap stops recording and returns the transcript. The user's
/// installed Shortcut wraps two invocations + clipboard copy.
///
/// Without the PushToTalk entitlement (Tier 2), the main app must be
/// "alive enough" to handle the intent. In practice: warm mode keeps it
/// resident, and iOS will resume a suspended app briefly to run an
/// AppIntent invoked via Shortcuts. PTT only adds the
/// instant-wake-from-fully-suspended capability.
// AudioRecordingIntent removed — adopting it without the
// com.apple.developer.push-to-talk entitlement appears to cause iOS to
// SIGTRAP at launch when registering the AppShortcutsProvider. We can
// add it back once Tier 2 (the PTT entitlement) lands; the protocol is
// purely a marker that affects the recording-indicator UI, not the
// AppIntent's ability to be invoked from a Shortcut. The keyboard path
// still works without it because the app's existing audio session
// handles the actual recording.
struct ToggleRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Recording"
    static var description = IntentDescription(
        "Start a Shhhcribble recording. Run again to stop and return the transcript."
    )
    /// Critical: false. Foregrounding would defeat the entire point.
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @Parameter(
        title: "Release Mic Immediately",
        description: "Release the mic immediately after stop instead of honoring the warm-mode session timeout.",
        default: false
    )
    var releaseMic: Bool

    init() {}

    /// `@MainActor` is required for `AudioRecordingIntent` per Apple's docs —
    /// the protocol implies UI-thread access for the mic activation flow.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let performer = Self.performer else {
            // Multi-target source membership: when compiled into the widget,
            // performer is never set (the intent runs in this process).
            // Returning empty is safe; Shortcuts will see no transcript.
            return .result(value: "")
        }
        let result = await performer(releaseMic)
        return .result(value: result)
    }

    /// Set by the main app at launch. Receives `releaseMic` and returns the
    /// transcript (empty string on start, transcript on stop). See
    /// `ShhhcribbleApp.init` where this gets wired up.
    static var performer: (@Sendable (Bool) async -> String)?
}
