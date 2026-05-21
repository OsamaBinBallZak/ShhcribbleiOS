import AVFoundation
import Combine
import Foundation
import ShhhcribbleShared
import UIKit
import os

private let diagLog = Logger(subsystem: "com.shhhcribble.diag", category: "service")

enum RecordingPhase: Equatable {
    case idle
    case recording
    case error(RecordingError)
}

enum RecordingError: Equatable {
    case micPermissionDenied
    case modelLoadFailed(String)
    case other(String)

    var message: String {
        switch self {
        case .micPermissionDenied:
            return "Microphone access is off. Enable it in Settings to record."
        case .modelLoadFailed(let detail):
            return "The transcription model couldn't load.\n\(detail)"
        case .other(let detail):
            return detail
        }
    }
}

// Note: AsrMode (streaming + tdt) was removed 2026-05-20. We now use
// only Parakeet TDT v3. The streaming engine had no punctuation, took
// a slower path to first-result, and the dual-engine setup forced a
// 26-second CoreML cold-compile on first switch to TDT — bad UX for
// zero user-visible benefit. If we ever want streaming back, restore
// the enum + the corresponding branches in loadModel / performRecording /
// stopRecording (see git history pre-2026-05-20).

@MainActor
final class TranscriptionStatus: ObservableObject {
    static let shared = TranscriptionStatus()
    @Published var model: ModelStatus = .notLoaded
    @Published var lastEvent: String = ""
    @Published var phase: RecordingPhase = .idle
    @Published var partialSnippet: String = ""
    @Published var launchedViaURL: Bool = false
    /// Smoothed mic input level, 0...1, for visualizers.
    @Published var audioLevel: Double = 0
    /// Fraction (0...1) of the current first-time model download.
    /// Non-nil only while FluidAudio is actively downloading bytes — nil
    /// during listing, compiling, and after the model is cached. Drives
    /// the play-button progress ring; users only ever see this on a fresh
    /// install or the first time they switch to a not-yet-downloaded engine.
    @Published var modelDownloadProgress: Double?
    /// Non-nil while a recording is running in append-to-note mode. The
    /// recording overlay reads this to render an "Adding to: <title>" chip
    /// so the user knows the transcript will be appended rather than create
    /// a fresh note. Cleared on every terminal state.
    @Published var appendTargetTitle: String?
    /// True when the audio engine is running but no buffers have arrived
    /// for the staleness threshold (~1.5 s). Most common cause: AirPods
    /// held by another device (Mac via Continuity), or the user pulled
    /// the AirPods just as recording started. Set by AudioInput's
    /// watchdog timer; the recording overlay reads this and renders a
    /// "Waiting for audio device…" banner so the user understands why
    /// the waveform isn't moving.
    @Published var audioDeviceUnavailable: Bool = false

    /// Single source of truth derives from `phase`. Existing call sites that
    /// only need to know "is the engine actively capturing audio" keep
    /// reading this without caring about the new error/noSpeech states.
    var isRecording: Bool { phase == .recording }

    /// True whenever the recording overlay should be visible — i.e. anything
    /// other than fully idle. Used by the overlay's visibility guard.
    var overlayVisible: Bool { phase != .idle }

    private init() {}

    func set(_ status: ModelStatus) { self.model = status }
    func event(_ text: String) {
        print("[Shhhcribble] \(text)")
        self.lastEvent = text
    }

    func setPhase(_ newPhase: RecordingPhase) {
        phase = newPhase
    }
}

/// `TranscriptionService` is the recording-lifecycle coordinator. It runs
/// the phase state machine and orchestrates the upstream `AudioInput` and
/// the downstream `TextEngine`. On stop it commits to SwiftData, writes
/// the transcript to the clipboard, hands off to the keyboard via the App
/// Group, schedules warm-mode idle expiry, and clears the Live Activity.
///
/// Recording flow (since Step 2): consume `AudioInput.shared.start(...)`
/// as a `for await buffer in stream` loop, feeding each buffer into
/// `TextEngine.shared.feed`. The stream finishes when `stopRecording` or
/// `cancelRecording` calls `AudioInput.stop()` / `AudioInput.cancel()`.
/// The loop exits naturally; the post-loop block branches on the
/// `cancelled` flag to either discard (cancel path) or finalize +
/// commit (stop path). No `CheckedContinuation` needed.
actor TranscriptionService {
    static let shared = TranscriptionService()

    private var recording = false
    private var stopRequested = false
    /// Set by `stopRecording` when called before `recordAndTranscribe`
    /// finished its init (race on the Darwin start/stop path). Honoured at
    /// the earliest stable point inside `recordAndTranscribe` — see below.
    private var pendingStopBeforeStart = false
    private var pendingCancelBeforeStart = false
    private var cancelled = false
    private var reloading = false

    /// The currently-running recording task, if any. Set in
    /// `recordAndTranscribe` to wrap the body; allows `stopRecording` /
    /// `cancelRecording` to do a synchronous `Task.cancel()` as a hard
    /// kill-switch when the actor state has drifted into an inconsistent
    /// state and the normal stream-finish path is stuck.
    private var recordingTask: Task<Void, Error>?

    private var tdtLiveTask: Task<Void, Never>?
    private var tdtLastLiveAt: Date?
    private var recordingStartedAt: Date?
    private var currentTrigger: TriggerSource = .manual
    /// When non-nil, `commit` appends the transcript to the existing note with
    /// this id instead of inserting a new one. Set at the start of
    /// `recordAndTranscribe` and cleared on every exit path.
    private var appendTargetId: UUID?
    private static let tdtLiveInterval: TimeInterval = 0.7

    private init() {}

    var isRecording: Bool { recording }

    /// Thin wrapper preserving the public name. Existing callers in
    /// `ShhhcribbleApp.init` keep working without churn; the actual
    /// model-load work lives in `TextEngine`.
    func ensureModelLoaded() async throws {
        try await TextEngine.shared.ensureLoaded()
    }

    func reloadModel() async {
        guard !recording else {
            await TranscriptionStatus.shared.event("Can't reload while recording")
            return
        }
        guard !reloading else {
            await TranscriptionStatus.shared.event("Reload already in progress")
            return
        }
        reloading = true
        defer { reloading = false }
        await TextEngine.shared.reload()
    }

    /// Graceful stop. Finishes the `AudioInput` stream; the for-await loop
    /// in `performRecording` exits, drives `TextEngine.finalize`, commits.
    func stopRecording() async {
        guard recording, !stopRequested else {
            if !recording {
                // Stop arrived before recordAndTranscribe finished initialising
                // (Darwin-notification path, short hold). Defer the stop to
                // the next stable point inside recordAndTranscribe.
                pendingStopBeforeStart = true
                await TranscriptionStatus.shared.event("Stop deferred until recording starts")
                // Hard kill-switch: if recording is in mid-init right now,
                // Task.cancel() will throw at the next checkCancellation()
                // even if the actor's mailbox can't reach us.
                recordingTask?.cancel()
            } else {
                await TranscriptionStatus.shared.event("Stop: already stopping or not recording")
                // Defensive: if state is desynced (in-app Cancel button
                // reports "already stopping or not recording" but the
                // user can still see the overlay), nuke the task too.
                recordingTask?.cancel()
            }
            return
        }
        stopRequested = true
        await TranscriptionStatus.shared.event("Manual stop")
        AudioInput.shared.stop()
    }

    /// Real abort — drop audio, skip transcription, skip SwiftData write,
    /// restore clipboard immediately. Invoked by the in-app Cancel button.
    func cancelRecording() async {
        guard recording, !stopRequested else {
            if !recording {
                pendingCancelBeforeStart = true
                await TranscriptionStatus.shared.event("Cancel deferred until recording starts")
                recordingTask?.cancel()
            } else {
                await TranscriptionStatus.shared.event("Cancel: already stopping or not recording")
                recordingTask?.cancel()
            }
            return
        }
        cancelled = true
        stopRequested = true
        await TranscriptionStatus.shared.event("Cancel")
        AudioInput.shared.cancel()
    }

    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    /// Public entry point. Wraps the body in an internal `Task` so callers
    /// of `stopRecording` / `cancelRecording` can hard-cancel via
    /// `Task.cancel()` if the stream-finish path gets stuck. The body
    /// throws `CancellationError` at any `Task.checkCancellation()`
    /// call site if cancel fires; we swallow it here so callers don't
    /// need to handle it.
    func recordAndTranscribe(
        trigger: TriggerSource = .manual,
        appendingTo: UUID? = nil
    ) async throws {
        guard !recording, recordingTask == nil else { return }
        let task = Task<Void, Error> { [weak self] in
            try await self?.performRecording(trigger: trigger, appendingTo: appendingTo)
        }
        self.recordingTask = task
        defer { self.recordingTask = nil }
        do {
            try await task.value
        } catch is CancellationError {
            await TranscriptionStatus.shared.event("Recording task cancelled via Task.cancel()")
        }
    }

    /// The actual recording body. Don't call directly — go through
    /// `recordAndTranscribe` so the task reference is captured and
    /// cancel can interrupt this body at any await point that runs
    /// `try Task.checkCancellation()`.
    private func performRecording(
        trigger: TriggerSource,
        appendingTo: UUID?
    ) async throws {
        // Claim the recording slot ATOMICALLY before any suspension point.
        // Without this, a Darwin-notification stop arriving during the
        // permission check sees `recording == false`, sets pendingStop,
        // and recordAndTranscribe bails before capturing any audio.
        recording = true
        stopRequested = false
        cancelled = false

        try Task.checkCancellation()

        // Pre-flight mic permission. Surface a typed error UX in the
        // recording overlay if denied.
        let perm = await MainActor.run { AVAudioApplication.shared.recordPermission }
        try Task.checkCancellation()
        switch perm {
        case .granted:
            break
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted {
                recording = false
                await TranscriptionStatus.shared.setPhase(.error(.micPermissionDenied))
                return
            }
        case .denied:
            recording = false
            await TranscriptionStatus.shared.setPhase(.error(.micPermissionDenied))
            return
        @unknown default:
            break
        }

        // If a stop/cancel was deferred during permission init (Darwin race),
        // do NOT bail — the user's hold likely captured something. Set the
        // normal stop flag and let recordAndTranscribe run its course; the
        // recording loop will see stopRequested and tear down immediately
        // after the engine is up.
        let stopAlready = pendingStopBeforeStart
        let cancelAlready = pendingCancelBeforeStart
        pendingStopBeforeStart = false
        pendingCancelBeforeStart = false
        if cancelAlready {
            cancelled = true
            stopRequested = true
            await TranscriptionStatus.shared.event("Deferred cancel — will tear down after engine starts")
        } else if stopAlready {
            stopRequested = true
            await TranscriptionStatus.shared.event("Deferred stop — will commit minimum-length recording")
        }
        await TextEngine.shared.reset()
        tdtLastLiveAt = nil
        recordingStartedAt = Date()
        currentTrigger = trigger
        appendTargetId = appendingTo
        if let id = appendingTo {
            let title = await NotesRepository.shared.title(for: id)
            await MainActor.run {
                TranscriptionStatus.shared.appendTargetTitle = title
            }
        } else {
            await MainActor.run {
                TranscriptionStatus.shared.appendTargetTitle = nil
            }
        }

        // For keyboard-triggered recordings, snapshot the user's existing
        // clipboard so we can restore it after autopaste — they didn't ask
        // us to clobber it just by holding the keyboard's mic. In-app
        // recordings deliberately leave the transcript on the clipboard
        // (see Hendri's CLAUDE.md note "ClipboardService is keyboard-only").
        if trigger == .keyboard {
            await ClipboardService.shared.snapshot()
        }

        // A recording is starting → cancel any pending warm-mode auto-expiry.
        // It'll be rescheduled in `commit` when this recording finishes.
        await MainActor.run {
            AudioInput.shared.cancelIdleExpiry()
        }

        // Clear any leftover partial snippet from a prior recording so the
        // RecordingView's typewriter starts from a clean slate. Without this
        // the previous transcript can ghost in for a moment when the overlay
        // re-appears, before the new partials start arriving.
        await MainActor.run {
            TranscriptionStatus.shared.partialSnippet = ""
        }

        // Claim background runtime so TDT transcription can complete after
        // the user taps the iOS back-pill and the scene phase flips to
        // .background. UIBackgroundModes=audio keeps us alive while recording;
        // this covers the post-stop transcription window.
        let taskId = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "Shhhcribble.transcribe") {
                // Expiration — iOS is about to kill us. Force-stop.
                Task { await TranscriptionService.shared.forceEndBackgroundTask() }
            }
        }
        self.bgTaskId = taskId
        await TranscriptionStatus.shared.event("Triggered")
        await setUIRecording(true)
        let activityOK = await MainActor.run { ShhhcribbleActivityManager.shared.start() }
        if !activityOK {
            await TranscriptionStatus.shared.event("Live Activity unavailable — continuing without it")
        }
        defer {
            recording = false
            stopRequested = false
            appendTargetId = nil
            let endId = self.bgTaskId
            self.bgTaskId = .invalid
            Task { @MainActor in
                // Only collapse to .idle if we're still mid-recording; if a
                // branch already moved us to .noSpeech or .error, leave that
                // state visible so the overlay can render the error UX.
                if TranscriptionStatus.shared.phase == .recording {
                    TranscriptionStatus.shared.setPhase(.idle)
                }
                TranscriptionStatus.shared.appendTargetTitle = nil
                if endId != .invalid {
                    UIApplication.shared.endBackgroundTask(endId)
                }
            }
            Task { @MainActor in
                ShhhcribbleActivityManager.shared.end()
            }
        }

        async let modelReady: Void = TextEngine.shared.ensureLoaded()

        try Task.checkCancellation()

        // Bring the mic up. `AudioInput.start` returns an AsyncStream that
        // we consume directly with for-await; teardown happens when
        // `stopRecording` / `cancelRecording` call `AudioInput.stop()` /
        // `AudioInput.cancel()` which finish the stream.
        let stream: AsyncStream<AVAudioPCMBuffer>
        do {
            stream = try AudioInput.shared.start(onLevel: { level in
                Task { @MainActor in
                    TranscriptionStatus.shared.audioLevel = Double(level)
                }
            })
        } catch {
            await notifyError(.other("Recording failed to start."))
            return
        }

        // Wait for the model. If load fails or the task is cancelled, tear
        // down audio and surface the error.
        do {
            try await modelReady
        } catch is CancellationError {
            AudioInput.shared.cancel()
            throw CancellationError()
        } catch {
            AudioInput.shared.cancel()
            await notifyError(.modelLoadFailed(humaniseModelLoadError(error)))
            return
        }

        try Task.checkCancellation()

        await TranscriptionStatus.shared.event("Recording…")

        // If a stop or cancel arrived during pre-engine init (Darwin race),
        // honour it now — finish the stream so the for-await below exits
        // immediately.
        if stopRequested {
            await TranscriptionStatus.shared.event("Honouring pre-engine stop request — tearing down now")
            if cancelled {
                AudioInput.shared.cancel()
            } else {
                AudioInput.shared.stop()
            }
        }

        // No "Recording…" placeholder text. TypingViewModel uses a
        // hybrid prefix/snap/rewind/reject scheme which means any initial
        // partial that doesn't have prefix of the placeholder could leave
        // it stuck. The waveform animation + the overlay's title give
        // plenty of "recording is active" feedback; empty live text is
        // fine until the first TDT result arrives.
        await MainActor.run {
            TranscriptionStatus.shared.partialSnippet = ""
        }

        // Safety-net timer for the live snapshot in case the buffer-arrival
        // trigger misses (e.g. silence keeps the audio engine from delivering
        // buffers). Cancelled when the for-await loop exits.
        let live = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tdtLiveInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await TranscriptionService.shared.performLiveSnapshot()
            }
        }
        self.tdtLiveTask = live

        // Consume audio buffers directly. Loop exits when AudioInput.stop /
        // AudioInput.cancel finishes the stream — either via the explicit
        // stop/cancel public methods, or via the route-change handler if
        // the engine couldn't be rebuilt.
        for await buffer in stream {
            await TextEngine.shared.feed(buffer)
            await maybeKickLiveSnapshot()
        }

        self.tdtLiveTask?.cancel()
        self.tdtLiveTask = nil

        // Stream finished. Branch on cancel vs stop.
        if cancelled {
            await TranscriptionStatus.shared.event("Cancelled — discarding transcript")
            await TextEngine.shared.discard()
            await MainActor.run {
                TranscriptionStatus.shared.partialSnippet = ""
            }
            return
        }

        let transcript = await TextEngine.shared.finalize()
        await TranscriptionStatus.shared.event("Got: \"\(transcript)\"")

        // `transcript` is already vocabulary-filtered (`TextEngine.finalize`
        // applies the filler + substitution passes in one place). No further
        // transformation needed here.
        guard !transcript.isEmpty else {
            await TranscriptionStatus.shared.event("Empty transcript — no speech detected")
            await MainActor.run {
                TranscriptionStatus.shared.partialSnippet = ""
                TranscriptionStatus.shared.launchedViaURL = false
                ToastManager.shared.show("No speech detected", systemImage: "waveform.slash")
            }
            // Even on empty, wake the keyboard so its spinner clears and the
            // UI returns to the mic button. Otherwise the keyboard hangs in
            // "Transcribing…" until its 1-second poll catches up.
            if currentTrigger == .keyboard {
                KeyboardBridge.postDarwin(KeyboardBridge.darwinTranscriptReady)
            }
            // Idle expiry still counts even if no transcript landed.
            await MainActor.run {
                AudioInput.shared.scheduleIdleExpiry()
            }
            return
        }

        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let trigger = currentTrigger
        let target = appendTargetId
        await commit(transcript, duration: duration, trigger: trigger, appendingTo: target)
        await TranscriptionStatus.shared.event(target == nil ? "Copied to clipboard" : "Added to note")
        await maybeAutoBackground()
    }

    func forceEndBackgroundTask() async {
        await stopRecording()
    }

    /// Event-driven trigger: whenever fresh audio lands and enough time has
    /// elapsed since the last live snapshot, kick one off. Catches the
    /// tail of an utterance faster than the safety-net timer alone.
    private func maybeKickLiveSnapshot() async {
        guard !stopRequested else { return }
        let now = Date()
        if tdtLastLiveAt.map({ now.timeIntervalSince($0) >= Self.tdtLiveInterval }) ?? true {
            tdtLastLiveAt = now
            Task { await self.performLiveSnapshot() }
        }
    }

    /// Ask `TextEngine` for the current best-effort full transcript and
    /// publish it to `TranscriptionStatus.partialSnippet`, the clipboard
    /// (so a foregrounded user can paste mid-dictation), and the Live
    /// Activity. Only writes pasteboard + Live Activity when the snippet
    /// is non-empty so we don't clobber the user's prior clipboard before
    /// the first TDT result arrives.
    private func performLiveSnapshot() async {
        guard !stopRequested else { return }
        let snippet = await TextEngine.shared.liveSnapshot()
        let liveActivitySnippet = String(snippet.suffix(200))
        await MainActor.run {
            TranscriptionStatus.shared.partialSnippet = snippet
            if !snippet.isEmpty {
                UIPasteboard.general.string = snippet
                ShhhcribbleActivityManager.shared.update(snippet: liveActivitySnippet)
            }
        }
    }

    @MainActor
    private func maybeAutoBackground() {
        // No longer sends the app home. When user taps the system "← Back"
        // pill iOS renders in the top-left for URL-scheme launches, the scene
        // phase observer in the App stops recording & commits.
        guard TranscriptionStatus.shared.launchedViaURL else { return }
        TranscriptionStatus.shared.launchedViaURL = false
        TranscriptionStatus.shared.partialSnippet = ""
    }

    @MainActor
    private func setUIRecording(_ value: Bool) {
        TranscriptionStatus.shared.setPhase(value ? .recording : .idle)
    }

    @MainActor
    private func commit(
        _ text: String,
        duration: TimeInterval,
        trigger: TriggerSource,
        appendingTo: UUID?
    ) {
        UIPasteboard.general.string = text
        if trigger == .keyboard {
            // Write to App Group so the keyboard extension can pick it up
            // and inject via UITextDocumentProxy when the user returns to
            // the host text field. Darwin notification wakes the keyboard's
            // observer immediately; the timer-based poll + textDidChange
            // covers the case where the extension was suspended.
            KeyboardBridge.writeTranscript(text)
            KeyboardBridge.postDarwin(KeyboardBridge.darwinTranscriptReady)
            // Restore the user's original clipboard after 2 s so the
            // transcript is briefly pasteable as a fallback (if
            // `textDocumentProxy.insertText` is silently dropped by the
            // host app), then their prior content comes back. Skipped if
            // they manually copied something else in the meantime —
            // `scheduleRestore` checks the changeCount before restoring.
            Task { await ClipboardService.shared.scheduleRestore(after: 2.0) }
        }
        if let id = appendingTo {
            NotesRepository.shared.append(transcript: text, to: id)
            ToastManager.shared.show("Added to note", systemImage: "text.append")
        } else {
            NotesRepository.shared.insert(
                transcript: text,
                duration: duration,
                trigger: trigger
            )
            // Toast handles the success haptic so we don't double up.
            let toastMessage = trigger == .keyboard
                ? "Ready — switch back to insert"
                : "Copied to clipboard"
            let toastIcon = trigger == .keyboard
                ? "keyboard"
                : "doc.on.doc.fill"
            ToastManager.shared.show(toastMessage, systemImage: toastIcon)
        }
        // Recording finalised — start the warm-mode idle countdown.
        // If the user picked "Always" in Settings, this is a no-op.
        AudioInput.shared.scheduleIdleExpiry()
    }

    @MainActor
    private func notifyError(_ error: RecordingError) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        TranscriptionStatus.shared.partialSnippet = ""
        TranscriptionStatus.shared.launchedViaURL = false
        TranscriptionStatus.shared.setPhase(.error(error))
    }
}
