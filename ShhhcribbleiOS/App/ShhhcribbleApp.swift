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
        AudioSessionManager.shared.configure()
        // Warm mode disabled — `.playAndRecord` with a silent player
        // engine corrupts the input node format on iOS 26 (crashes in
        // installTap with IsFormatSampleRateAndChannelCountValid).
        // For now the app gets suspended after backgrounding and the
        // keyboard's warm path doesn't survive that. To be fixed in a
        // follow-up with a different keepalive strategy.
        AudioInterruptionObserver.shared.start()
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
        Task.detached(priority: .userInitiated) {
            try? await TranscriptionService.shared.ensureModelLoaded()
        }
        // Sweep up any Live Activities that survived a prior crash or kill —
        // without this they accumulate as ghost banners across launches.
        Task { @MainActor in
            ShhhcribbleActivityManager.shared.reapOrphanedActivities()
        }

        // Keyboard-extension push-to-talk plumbing. While the main app is
        // alive, heartbeat to the App Group so the keyboard knows it can
        // use the warm path (Darwin notification only — no app launch).
        KeyboardBridge.heartbeat()
        let initialReadback = KeyboardBridge.defaults?.object(forKey: "keyboard.engineKeepAlive")
        print("[Shhhcribble] init heartbeat written, readback=\(String(describing: initialReadback)), appGroupID=\(KeyboardBridge.appGroupID), defaults=\(KeyboardBridge.defaults == nil ? "NIL" : "OK")")
        Task.detached(priority: .background) {
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                KeyboardBridge.heartbeat()
                n += 1
                if n % 2 == 0 {
                    print("[Shhhcribble] heartbeat tick \(n)")
                }
            }
        }
        // Both transports run concurrently: Darwin for low-latency wake,
        // App Group polling for redundancy. With warm mode keeping the app
        // alive, both should work; the first to arrive wins (start/stop is
        // idempotent in the actor — guard at top of recordAndTranscribe).
        registerKeyboardDarwinObservers()
        startKeyboardSignalPolling()
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
                    Task.detached(priority: .userInitiated) {
                        do {
                            try await TranscriptionService.shared.recordAndTranscribe(trigger: .keyboard)
                        } catch {
                            print("[Shhhcribble] PTT start -> recordAndTranscribe failed: \(error)")
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
        case "record-from-keyboard":
            // Keyboard extension wrote KeyboardBridge.Signal.startRecording
            // and then called extensionContext.open(recordURL) — we land
            // here. Trigger source `.keyboard` flags commit() to write the
            // transcript back to the App Group container instead of (or
            // in addition to) the clipboard, so the keyboard can pick it
            // up on the user's return.
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
