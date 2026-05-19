import AppIntents

struct ShhhcribbleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Single Siri-discoverable shortcut, matching Superwhisper exactly:
        // one phrase template, glyph `record.circle`. Audit M3 — extra
        // shortcuts (Start, Record with…) dilute Siri match confidence.
        // The StartRecordingIntent / StopRecordingIntent / CancelRecordingIntent
        // types still exist for the widget's Control Center button +
        // Live Activity buttons; we just don't expose them as Siri
        // shortcuts here.
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
