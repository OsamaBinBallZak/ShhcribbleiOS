import ShhhcribbleShared
import SwiftData
import SwiftUI
import os

private let diagLog = Logger(subsystem: "com.shhhcribble.diag", category: "app")

/// CFNotificationCenter observer tokens must point to a stable address.
/// We can't use `self` here because `ShhhcribbleApp` is a value type and
/// its `init` references would be unstable. Use a static class anchor.
private final class KeyboardDarwinAnchor {
    static let shared = KeyboardDarwinAnchor()
    private init() {}
}

@main
struct ShhhcribbleApp: App {
    @StateObject private var status = TranscriptionStatus.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false

    init() {
        AudioInput.shared.configure()
        // Warm mode at launch: only if the user picked "Always" in Settings.
        // Default (off + 60s) means the dot only shows during active
        // sessions. Each keyboard cold-start opens the app, enters warm
        // mode + starts recording, then auto-exits 60s after the last
        // recording ends.
        if UserDefaults.standard.bool(forKey: "warmModeAlways") {
            AudioInput.shared.enterWarmMode()
        }
        AudioInput.shared.startObservingInterruptions()
        // Phase J Tier 2 — Push to Talk entitlement + background mode
        // are kept (they extend our background runtime), but we do NOT
        // link PushToTalk.framework. Superwhisper's IPA confirms they
        // don't either — the entitlement alone is what matters. The
        // previous PushToTalkService.swift was deleted (S1 of the
        // 3-Opus audit on 2026-05-19).
        //
        // Side effect: any previously-joined PT channel persists in iOS
        // until the user deletes + reinstalls the app. If you see the
        // system "Talk" bar showing, delete the app and reinstall.
        StopRecordingIntent.performer = {
            await TranscriptionService.shared.stopRecording()
        }
        CancelRecordingIntent.performer = {
            // Cancel from the Live Activity currently behaves identically
            // to Stop (commits the recording). Real abort lives in the
            // in-app Cancel button via TranscriptionService.cancelRecording.
            await TranscriptionService.shared.stopRecording()
        }
        StartRecordingIntent.performer = { @MainActor in
            let service = TranscriptionService.shared
            let status = TranscriptionStatus.shared
            if status.isRecording {
                Task.detached { await service.stopRecording() }
                return
            }
            // Flip the overlay synchronously so it covers the launch flash
            // before the actor hop inside recordAndTranscribe can run. Same
            // pattern as the URL-scheme handler in `handle(url:)`.
            status.setPhase(.recording)
            // Fire-and-forget: awaiting recordAndTranscribe here would keep
            // Siri's "Working…" panel up for the whole recording, which
            // absorbs touches and makes Stop / Cancel inert.
            Task.detached(priority: .userInitiated) {
                do {
                    try await service.recordAndTranscribe(trigger: .manual)
                } catch {
                    let msg = String(describing: error)
                    diagLog.error("recordAndTranscribe threw \(msg, privacy: .public)")
                    await MainActor.run {
                        status.setPhase(.error(.other(msg)))
                    }
                }
            }
        }
        // Phase J Tier 1 — the no-app-switch path. ToggleRecordingIntent
        // is invoked by the user-installed Shhhcribble Shortcut, which the
        // keyboard's mic button fires via `shortcuts://run-shortcut?name=...`.
        // openAppWhenRun=false on the intent means iOS runs perform() in
        // this process without foregrounding the app, so the host app
        // (Notes, Messages, etc.) stays on screen.
        ToggleRecordingIntent.performer = { @MainActor releaseMic in
            let service = TranscriptionService.shared
            if await service.isRecording {
                // STOP path. Record timestamp before stop so we can detect
                // the new transcript landing in App Group.
                let preStop = KeyboardBridge.transcriptReadyAt
                await service.stopRecording()
                // Poll App Group for the transcript (max 30 s). Recording
                // finalisation includes the ASR pass which can take a few
                // seconds; 30 s is a generous ceiling.
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    if let readyAt = KeyboardBridge.transcriptReadyAt,
                       readyAt != preStop {
                        let transcript = KeyboardBridge.consumeTranscript() ?? ""
                        if releaseMic {
                            AudioInput.shared.exitWarmMode()
                        }
                        return transcript
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return ""
            } else {
                // START path. Fire-and-forget the recording so perform()
                // returns immediately (the user will tap mic again to stop).
                Task.detached(priority: .userInitiated) {
                    try? await service.recordAndTranscribe(trigger: .keyboard)
                }
                // Brief pause so a fast double-tap doesn't race the
                // recording-flag claim inside performRecording.
                try? await Task.sleep(for: .milliseconds(200))
                return ""
            }
        }
        Task.detached(priority: .userInitiated) {
            try? await TranscriptionService.shared.ensureModelLoaded()
        }
        // Sweep up any Live Activities that survived a prior crash or kill —
        // without this they accumulate as ghost banners across launches.
        Task { @MainActor in
            ShhhcribbleActivityManager.shared.reapOrphanedActivities()
        }

        // Heartbeat + Darwin/polling observers stay registered for the
        // app's lifetime. The heartbeat itself only WRITES while warm mode
        // is active so the keyboard's "engine warm" check correctly
        // reflects whether the audio engine is actually ready.
        print("[Shhhcribble] App Group: \(KeyboardBridge.appGroupID), defaults=\(KeyboardBridge.defaults == nil ? "NIL" : "OK")")
        Task.detached(priority: .background) {
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if AudioInput.shared.warmModeActive {
                    KeyboardBridge.heartbeat()
                    n += 1
                    if n % 2 == 0 {
                        print("[Shhhcribble] heartbeat tick \(n) (warm)")
                    }
                }
            }
        }
        // Both transports run concurrently: Darwin for low-latency wake,
        // App Group polling for redundancy. With warm mode keeping the app
        // alive, both should work; the first to arrive wins (start/stop is
        // idempotent in the actor — guard at top of recordAndTranscribe).
        registerKeyboardDarwinObservers()
        startKeyboardSignalPolling()
        startKeyboardDebugLogDrain()
    }

    /// Poll the App Group debug-log key and print anything the keyboard
    /// has written. devicectl --console only captures the main app's
    /// stdout, so this is the only way to see keyboard logs.
    private func startKeyboardDebugLogDrain() {
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let entries = KeyboardBridge.drainDebugLog()
                for entry in entries {
                    print("[Shhhcribble] \(entry)")
                }
            }
        }
    }

    /// Poll the App Group every 100 ms for keyboard PTT signals. We
    /// confirmed Darwin notifications don't cross the extension/app
    /// sandbox boundary on iOS 26 — this is the fallback.
    private func startKeyboardSignalPolling() {
        Task.detached(priority: .userInitiated) {
            // Seed lastSeen with whatever's already in the App Group so we
            // don't fire a phantom recording from a stale signal left over
            // from a previous app run.
            var lastSeen: Date? = KeyboardBridge.readPTTSignal()?.at ?? Date()
            print("[Shhhcribble] PTT polling started, ignoring signals at or before \(String(describing: lastSeen))")
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let signal = KeyboardBridge.readPTTSignal() else { continue }
                if let prev = lastSeen, signal.at <= prev { continue }
                lastSeen = signal.at
                print("[Shhhcribble] PTT signal: \(signal.signal.rawValue) at \(signal.at)")
                switch signal.signal {
                case .start:
                    // Direct path: call TranscriptionService.recordAndTranscribe.
                    // (Earlier this routed through PushToTalkService.beginTransmission
                    // — that service was removed in the S1 cleanup since Superwhisper
                    // doesn't link PT framework either; the entitlement alone gives
                    // background runtime.)
                    Task.detached(priority: .userInitiated) {
                        do {
                            try await TranscriptionService.shared.recordAndTranscribe(trigger: .keyboard)
                        } catch {
                            print("[Shhhcribble] PTT start → recordAndTranscribe failed: \(error)")
                        }
                    }
                case .stop:
                    Task.detached(priority: .userInitiated) {
                        await TranscriptionService.shared.stopRecording()
                    }
                }
            }
        }
    }

    /// Registered once at launch. Survives backgrounding — Darwin
    /// notifications wake the process briefly even while suspended,
    /// long enough for the audio session to claim and start recording.
    private func registerKeyboardDarwinObservers() {
        let token = Unmanaged.passUnretained(KeyboardDarwinAnchor.shared).toOpaque()

        KeyboardBridge.observeDarwin(
            KeyboardBridge.darwinStart,
            observer: UnsafeRawPointer(token)
        ) { _, _, _, _, _ in
            print("[Shhhcribble] darwinStart received")
            Task.detached(priority: .userInitiated) {
                do {
                    try await TranscriptionService.shared.recordAndTranscribe(trigger: .keyboard)
                } catch {
                    print("[Shhhcribble] darwinStart -> recordAndTranscribe failed: \(error)")
                }
            }
        }

        KeyboardBridge.observeDarwin(
            KeyboardBridge.darwinStop,
            observer: UnsafeRawPointer(token)
        ) { _, _, _, _, _ in
            print("[Shhhcribble] darwinStop received")
            Task.detached(priority: .userInitiated) {
                await TranscriptionService.shared.stopRecording()
            }
        }
        print("[Shhhcribble] Darwin observers registered")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .overlay { RecordingOverlayView(status: status) }
                .animation(.spring(response: 0.42, dampingFraction: 0.78), value: status.overlayVisible)
                .onOpenURL { url in handle(url: url) }
                .fullScreenCover(isPresented: Binding(
                    get: { !onboardingComplete },
                    set: { _ in /* dismissal happens via the onboarding "Get Started" / Skip buttons flipping the flag */ }
                )) {
                    OnboardingView()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Only auto-stop on backgrounding when the recording was
                    // launched via URL scheme (e.g. Back Tap → Shortcut → app
                    // launches → user taps the "← Back to X" pill iOS shows
                    // at top-left). In that flow the back-pill IS the stop
                    // button, and we want the transcript to land on the
                    // clipboard before iOS ferries the user back.
                    //
                    // For recordings launched in-app (play button), keep
                    // recording across app switches — that's the whole point
                    // of background audio + the Live Activity. The user stops
                    // via the Live Activity's Stop button or by returning to
                    // the app.
                    if phase == .background
                        && status.isRecording
                        && status.launchedViaURL {
                        Task { await TranscriptionService.shared.stopRecording() }
                    }
                }
        }
        .modelContainer(NotesRepository.shared.container)
    }

    private func handle(url: URL) {
        guard url.scheme?.lowercased() == "shhhcribble" else { return }
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()

        switch action {
        case "record":
            startURLLaunchedRecording(trigger: .manual)
        case "record-from-keyboard", "keyboard":
            // Keyboard's cold-start button fired this URL. Enter warm mode
            // FIRST so the engine + audio session are alive, then start a
            // recording. The user is now in the foreground watching the
            // live transcript; subsequent recordings within the idle window
            // skip the app-switch entirely.
            // `keyboard` is the Superwhisper-style short form (no path),
            // `record-from-keyboard` is the legacy long form. Both work.
            if !AudioInput.shared.warmModeActive {
                AudioInput.shared.enterWarmMode()
            }
            startURLLaunchedRecording(trigger: .keyboard)
        case "stop":
            status.launchedViaURL = true
            Task { await TranscriptionService.shared.stopRecording() }
        default:
            break
        }
    }

    private func startURLLaunchedRecording(trigger: TriggerSource) {
        guard !status.isRecording else { return }
        // Flip synchronously so the overlay covers the launch flash before
        // the actor hop inside recordAndTranscribe can update it.
        status.setPhase(.recording)
        status.launchedViaURL = true
        Task {
            do {
                try await TranscriptionService.shared.recordAndTranscribe(trigger: trigger)
            } catch {
                await MainActor.run {
                    if status.phase == .recording { status.setPhase(.idle) }
                    status.launchedViaURL = false
                }
            }
        }
    }
}
