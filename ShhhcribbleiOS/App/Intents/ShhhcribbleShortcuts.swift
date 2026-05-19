import AppIntents

struct ShhhcribbleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start \(.applicationName)",
                "Record with \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
        // Phase J Tier 1 — the no-app-switch path. Auto-registers a
        // Shortcut in Shortcuts.app users can invoke from anywhere,
        // including via the keyboard's `shortcuts://run-shortcut?name=...`
        // bridge. Phrase template mirrors Superwhisper's
        // "Toggle Superwhisper Recording".
        // Mirror Superwhisper's pattern exactly: single phrase template
        // "Toggle ${applicationName} Recording" — extra phrases dilute
        // Siri's match confidence. SUPERWHISPER_RE.md.
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: [
                "Toggle \(.applicationName) Recording",
            ],
            shortTitle: "Toggle Recording",
            systemImageName: "record.circle"
        )
    }
}
