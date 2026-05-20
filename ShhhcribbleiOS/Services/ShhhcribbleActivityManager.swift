import ActivityKit
import Foundation
import ShhhcribbleShared

@MainActor
final class ShhhcribbleActivityManager {
    static let shared = ShhhcribbleActivityManager()
    private var activity: Activity<ShhhcribbleActivityAttributes>?
    private var startedAt: Date = Date()

    // Throttle Live Activity updates. Apple recommends a maximum of a few
    // updates per second; pushing every transcript partial (which can fire
    // multiple times per second under TDT live transcription) would burn
    // the budget and cause the system to drop or stall later updates.
    // ~250 ms feels smooth in tandem with the snippet's `.contentTransition(.opacity)`.
    private var lastSnippetPushAt: Date?
    private var pendingSnippet: String?
    private var pendingTask: Task<Void, Never>?
    private let snippetThrottle: TimeInterval = 0.25

    private init() {}

    var isRunning: Bool { activity != nil }

    /// End any pre-existing activities. Called at app launch to clean up
    /// orphans left behind when the app was killed mid-recording — iOS keeps
    /// the banner displayed even after the process dies, and our in-memory
    /// `activity` reference is gone, so without this they stack across
    /// relaunches.
    func reapOrphanedActivities() {
        let orphans = Activity<ShhhcribbleActivityAttributes>.activities
        guard !orphans.isEmpty else { return }
        for orphan in orphans {
            Task {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[Shhhcribble] Live Activities disabled in system settings")
            return false
        }
        if activity != nil { return true }
        // Reap any orphans defensively so a crash mid-recording can't leave
        // two banners side-by-side after the next start.
        reapOrphanedActivities()
        startedAt = Date()
        let attrs = ShhhcribbleActivityAttributes(startedAt: startedAt)
        let state = ShhhcribbleActivityAttributes.ContentState(
            status: .recording,
            snippet: "",
            startedAt: startedAt
        )
        do {
            activity = try Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            return true
        } catch {
            print("[Shhhcribble] Live Activity start failed: \(error)")
            return false
        }
    }

    func update(snippet: String) {
        guard activity != nil else { return }
        pendingSnippet = snippet

        let now = Date()
        let elapsed = lastSnippetPushAt.map { now.timeIntervalSince($0) } ?? .infinity
        if elapsed >= snippetThrottle {
            pushPendingSnippet()
        } else if pendingTask == nil {
            // Schedule a single trailing push so the very last character a
            // user speaks always lands in the Live Activity even if it comes
            // inside the throttle window.
            let delay = snippetThrottle - elapsed
            pendingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                await MainActor.run { self?.pushPendingSnippet() }
            }
        }
    }

    private func pushPendingSnippet() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let activity, let snippet = pendingSnippet else { return }
        pendingSnippet = nil
        lastSnippetPushAt = Date()
        let state = ShhhcribbleActivityAttributes.ContentState(
            status: .recording,
            snippet: snippet,
            startedAt: startedAt
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingSnippet = nil
        lastSnippetPushAt = nil
        guard let activity else { return }
        let state = ShhhcribbleActivityAttributes.ContentState(
            status: .stopping,
            snippet: "",
            startedAt: startedAt
        )
        Task {
            await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}
