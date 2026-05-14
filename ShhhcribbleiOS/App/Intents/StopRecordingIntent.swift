import AppIntents

struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Shhhcribble Recording"
    // Runs in-process via App Group cross-process intent routing. Restored
    // 2026-05-14 after paid Developer Program enrolment + App Group reinstated.
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    static var performer: (@Sendable () async -> Void)?

    init() {}

    func perform() async throws -> some IntentResult {
        await Self.performer?()
        return .result()
    }
}
