import Foundation

/// Cross-process bridge between the main app and the keyboard extension.
/// Both targets link `ShhhcribbleShared`, so both see the same constants.
///
/// Two transport layers, used together:
///
/// 1. **Darwin notifications** (`CFNotificationCenterGetDarwinNotifyCenter`)
///    for low-latency cross-process wake-ups. UserDefaults KVO doesn't
///    fire reliably across processes; Darwin notifications do (~10 ms).
///
/// 2. **App Group `UserDefaults`** (suite `group.com.shhhcribble.app`)
///    for the payloads — short strings and timestamps. Darwin
///    notifications themselves carry no payload, so the listener reads
///    the latest payload from UserDefaults after receiving the signal.
///
/// Direction:
///   - keyboard → main:  post `.startRecording` / `.stopRecording`.
///                       Cold-start (engine not alive): keyboard calls
///                       `extensionContext.open(recordURL)` to bootstrap.
///   - main → keyboard:  write transcript + timestamp, post
///                       `.transcriptReady`. Keyboard observes and
///                       inserts via `textDocumentProxy.insertText`.
///   - main heartbeat:   while audio session is alive, main writes
///                       `engineKeepAlive = Date()` every ~5 s so the
///                       keyboard can decide cold-start vs warm path.
public enum KeyboardBridge {
    public static let appGroupID = "group.com.shhhcribble.app"
    public static let urlScheme = "shhhcribble"
    /// URL the keyboard fires to drive dictation.
    ///
    /// Phase J Tier 1 (2026-05-19): Shortcuts URL. iOS allows keyboard
    /// extensions to open `shortcuts://` because Shortcuts is a system
    /// app. The Shortcut runs our `ToggleRecordingIntent` (which conforms
    /// to `AudioRecordingIntent`) in this app's process WITHOUT
    /// foregrounding it — host app (Notes, Messages, etc.) stays on
    /// screen. The intent toggles recording: first invocation starts,
    /// second invocation stops + returns the transcript, which the
    /// user-installed Shortcut copies to the clipboard, which the keyboard
    /// reads and inserts via UITextDocumentProxy.
    ///
    /// Reverse-engineered from Superwhisper — see SUPERWHISPER_RE.md.
    ///
    /// User must install the Shhhcribble Shortcut in Shortcuts.app for
    /// this URL to do anything. Onboarding handles the deep link to
    /// install it. Without the shortcut, `extensionContext.open` opens
    /// Shortcuts.app to a "Shortcut not found" screen.
    public static let recordURL = URL(string: "shortcuts://run-shortcut?name=Toggle%20Shhhcribble%20Recording")!

    /// Fallback URL for the legacy "open the main app" cold-start path.
    /// Currently broken from keyboard extensions on iOS 26.4 — kept for
    /// when we figure out why Superwhisper's equivalent works and ours
    /// doesn't (signing? trusted-bundle? See SUPERWHISPER_RE.md).
    public static let appOpenURL = URL(string: "shhhcribble://record-from-keyboard")!

    /// How fresh `engineKeepAlive` must be for the warm-path Darwin
    /// notification to be considered viable. Two heartbeat intervals.
    public static let keepAliveStale: TimeInterval = 12

    // MARK: Darwin notification names

    public static let darwinStart = "com.shhhcribble.darwin.start" as CFString
    public static let darwinStop = "com.shhhcribble.darwin.stop" as CFString
    public static let darwinTranscriptReady = "com.shhhcribble.darwin.transcript" as CFString

    // MARK: Keys

    private enum Key {
        static let transcript = "keyboard.transcript"
        static let transcriptReadyAt = "keyboard.transcriptReadyAt"
        static let engineKeepAlive = "keyboard.engineKeepAlive"
        static let pttSignal = "keyboard.pttSignal"          // "start" | "stop"
        static let pttSignalAt = "keyboard.pttSignalAt"      // Date
        static let recordingActive = "keyboard.recordingActive"      // Bool
        static let recordingActiveAt = "keyboard.recordingActiveAt"  // Date
        static let debugLog = "keyboard.debugLog"            // [String] of recent log lines
    }

    // MARK: Debug log (keyboard writes, main app reads + prints)
    //
    // `devicectl --console` only captures the main app's stdout. Keyboard
    // extension prints are invisible. This rolls a small ring of log
    // lines through App Group so the main app can surface them.

    public static func debug(_ line: String) {
        let prefix = "[kb \(Self.shortTimestamp())] "
        let entry = prefix + line
        var log = (defaults?.array(forKey: Key.debugLog) as? [String]) ?? []
        log.append(entry)
        // Cap so we don't grow forever.
        if log.count > 100 { log = Array(log.suffix(50)) }
        defaults?.set(log, forKey: Key.debugLog)
    }

    /// Pop everything from the debug log. Main app calls this periodically.
    public static func drainDebugLog() -> [String] {
        let log = (defaults?.array(forKey: Key.debugLog) as? [String]) ?? []
        defaults?.removeObject(forKey: Key.debugLog)
        return log
    }

    private static func shortTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    // MARK: PTT signal (keyboard → main, App Group polling)
    // Darwin notifications turned out to be unreliable across the
    // extension/app sandbox boundary on iOS — confirmed in-process but
    // not received from the keyboard extension. App Group UserDefaults
    // polling is slower (~100 ms latency) but reliable.

    public enum PTTSignal: String {
        case start
        case stop
    }

    public static func writePTTSignal(_ signal: PTTSignal) {
        defaults?.set(signal.rawValue, forKey: Key.pttSignal)
        defaults?.set(Date(), forKey: Key.pttSignalAt)
    }

    /// Returns the latest PTT signal + timestamp, or nil if none/cleared.
    public static func readPTTSignal() -> (signal: PTTSignal, at: Date)? {
        guard
            let raw = defaults?.string(forKey: Key.pttSignal),
            let signal = PTTSignal(rawValue: raw),
            let at = defaults?.object(forKey: Key.pttSignalAt) as? Date
        else { return nil }
        return (signal, at)
    }

    public static func clearPTTSignal() {
        defaults?.removeObject(forKey: Key.pttSignal)
        defaults?.removeObject(forKey: Key.pttSignalAt)
    }

    /// Shared UserDefaults handle. Nil only if the App Group entitlement is
    /// misconfigured — callers should fail soft (do nothing) rather than crash.
    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: Recording-active flag (main app writes, keyboard reads)
    //
    // Set by `AudioRecorder.start()` / cleared in `stop()` so the
    // keyboard can show a different button when an in-app recording
    // is live. Keyboard's mic button: blue (warm idle) → red (Stop,
    // recording active).

    public static func setRecordingActive(_ active: Bool) {
        defaults?.set(active, forKey: Key.recordingActive)
        defaults?.set(Date(), forKey: Key.recordingActiveAt)
    }

    public static var isRecordingActive: Bool {
        defaults?.bool(forKey: Key.recordingActive) ?? false
    }

    // MARK: Engine keepalive (main app writes, keyboard reads)

    /// Main app calls this every ~5 s while audio session is alive.
    public static func heartbeat() {
        defaults?.set(Date(), forKey: Key.engineKeepAlive)
    }

    /// True if the main app heartbeated within the last `keepAliveStale` seconds.
    public static var isEngineWarm: Bool {
        guard let last = defaults?.object(forKey: Key.engineKeepAlive) as? Date else { return false }
        return Date().timeIntervalSince(last) < keepAliveStale
    }

    // MARK: Transcript handoff (main → keyboard)

    public static func writeTranscript(_ text: String) {
        guard !text.isEmpty else { return }
        defaults?.set(text, forKey: Key.transcript)
        defaults?.set(Date(), forKey: Key.transcriptReadyAt)
    }

    /// Reads any pending transcript and clears it.
    public static func consumeTranscript() -> String? {
        guard let text = defaults?.string(forKey: Key.transcript),
              !text.isEmpty else { return nil }
        defaults?.removeObject(forKey: Key.transcript)
        defaults?.removeObject(forKey: Key.transcriptReadyAt)
        return text
    }

    public static var transcriptReadyAt: Date? {
        defaults?.object(forKey: Key.transcriptReadyAt) as? Date
    }

    // MARK: Darwin notification helpers

    /// Post a Darwin notification. Cross-process, payload-less, fast.
    public static func postDarwin(_ name: CFString) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name), nil, nil, true)
    }

    /// Add an observer. Caller is responsible for removing on deinit.
    /// Note: the `userInfo` passed to Darwin observers is always nil — use
    /// the App Group `UserDefaults` for any payload.
    public static func observeDarwin(
        _ name: CFString,
        observer: UnsafeRawPointer,
        callback: @escaping CFNotificationCallback
    ) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            observer,
            callback,
            name,
            nil,
            .deliverImmediately
        )
    }

    public static func removeDarwinObserver(_ observer: UnsafeRawPointer) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, observer)
    }
}
