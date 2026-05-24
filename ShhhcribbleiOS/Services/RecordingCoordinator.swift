import AVFoundation
import Combine
import Foundation
import ShhhcribbleShared
import UIKit
import os

private let diagLog = Logger(subsystem: "com.shhhcribble.diag", category: "coordinator")

/// Recording lifecycle phase. The state machine is small and flat — three
/// cases — but the legal transitions are documented + validated via
/// `canTransition(to:)` so future contributors get an early signal if
/// they accidentally short-circuit the machine.
///
/// Legal transitions:
///   .idle      → .recording, .error
///   .recording → .idle, .error
///   .error     → .idle, .recording
/// Self-transitions are allowed (no-op).
///
/// "No speech detected" is NOT a phase — it surfaces via toast and the
/// phase collapses to .idle. See `RecordingCoordinator.performRecording`.
enum RecordingPhase: Equatable {
    case idle
    case recording
    case error(RecordingError)

    /// True if `next` is a legal successor of `self`. Used by
    /// `TranscriptionStatus.setPhase` to warn on illegal transitions
    /// without blocking them — the new phase is always applied so the
    /// UI never gets stuck in an inconsistent state.
    func canTransition(to next: RecordingPhase) -> Bool {
        switch (self, next) {
        // Same-state transitions are always allowed.
        case (.idle, .idle),
             (.recording, .recording),
             (.error, .error):
            return true
        // All cross-state transitions among the three phases are
        // legal. The model is flat by design (CLAUDE.md "Recording
        // phase state machine"). If a future change adds a phase
        // like `.transcribing` or `.saving`, update this graph.
        case (.idle, .recording),
             (.idle, .error),
             (.recording, .idle),
             (.recording, .error),
             (.error, .idle),
             (.error, .recording):
            return true
        }
    }
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

/// `RecordingCoordinator` is the recording-lifecycle coordinator. It runs
/// the phase state machine and orchestrates the upstream `AudioInput` and
/// the downstream `TextEngine`. On stop it commits to SwiftData, writes
/// the transcript to the clipboard, hands off to the keyboard via the App
/// Group, schedules warm-mode idle expiry, and clears the Live Activity.
///
/// Recording flow: consume `AudioInput.shared.start(...)` as a
/// `for await buffer in stream` loop, feeding each buffer into
/// `TextEngine.shared.feed`. The stream finishes when `stopRecording` or
/// `cancelRecording` calls `AudioInput.stop()` / `AudioInput.cancel()`.
/// The loop exits naturally; the post-loop block branches on the
/// `cancelled` flag to either discard (cancel path) or finalize +
/// commit (stop path). No `CheckedContinuation` needed.
actor RecordingCoordinator {
    static let shared = RecordingCoordinator()

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

    /// Fix A (backlog #2): the keyboard fires THREE simultaneous start
    /// signals on a single mic-tap — Darwin notification, App Group PTT
    /// signal, and a `shhhcribble://keyboard` URL open. All three race
    /// into the main app's observers (`registerKeyboardDarwinObservers`,
    /// `startKeyboardSignalPolling`, `.onOpenURL`). The actor guard at
    /// the top of `recordAndTranscribe` dedupes the BODY, but each
    /// caller's wrapping `Task.detached` carries its own cancel
    /// capability, and the desync bug shows that even idempotent calls
    /// can race in subtle ways during init.
    ///
    /// This wrapper debounces the keyboard start signals at the entry
    /// point with a 250 ms window. First signal in the window proceeds
    /// to `recordAndTranscribe`; subsequent signals are no-ops. The
    /// timestamp is NOT reset on completion — it's only consulted as a
    /// "did we just see a keyboard start" check, so a recording starting
    /// 250 ms after the last one is allowed.
    private var lastKeyboardStartAt: Date?
    private static let keyboardStartDebounceWindow: TimeInterval = 0.25

    /// Single entry point for ALL keyboard-triggered start signals.
    /// Routes Darwin / PTT / URL paths through one debouncer.
    func keyboardRecordAndTranscribe() async throws {
        let now = Date()
        if let last = lastKeyboardStartAt,
           now.timeIntervalSince(last) < Self.keyboardStartDebounceWindow {
            await TranscriptionStatus.shared.event("Keyboard start deduped (within \(Self.keyboardStartDebounceWindow)s window)")
            return
        }
        lastKeyboardStartAt = now
        try await recordAndTranscribe(trigger: .keyboard)
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
        await TranscriptionStatus.shared.event("Manual stop — draining 250ms")
        // Short drain before tearing down the mic. Users naturally tap
        // Stop ~100-300ms after the last word leaves their mouth; without
        // this pause the tap is removed before iOS has delivered the
        // tail buffer, so the closing syllables / final sentence go
        // missing. The for-await loop in `performRecording` keeps feeding
        // those buffers into `TextEngine.feed` for the whole window.
        // 250ms is below the perception threshold for tap-stop latency.
        try? await Task.sleep(nanoseconds: 250_000_000)
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
            // Fix C (backlog #2): belt-and-braces cleanup. With Fix B the
            // hoisted `defer` inside `performRecording` should already
            // have reset state when the task cancelled. This explicit
            // reset covers the edge case where cancel landed before
            // `recording = true` was assigned (defer not yet registered),
            // and any future refactor that might re-introduce the gap.
            if recording {
                recording = false
                stopRequested = false
                await MainActor.run {
                    if TranscriptionStatus.shared.phase == .recording {
                        TranscriptionStatus.shared.setPhase(.idle)
                    }
                }
            }
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

        // Fix B (backlog #2): defer block registered BEFORE the first
        // cancellable await/checkCancellation. Earlier this block lived
        // ~100 lines down (post-setUIRecording) so any `Task.cancel()`
        // from a duplicate stop signal during init would throw past the
        // cleanup, leaving `recording = true` and `phase = .recording`
        // permanently stuck. With the defer up here, ANY exit path —
        // cancellation, error, mid-init bail — cleans up actor state.
        defer {
            recording = false
            stopRequested = false
            appendTargetId = nil
            let endId = self.bgTaskId
            self.bgTaskId = .invalid
            Task { @MainActor in
                // Only collapse to .idle if we're still mid-recording; if a
                // branch already moved us to an error state, leave that
                // visible so the overlay can render the error UX.
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
            // Clear live-stream data so the keyboard pill doesn't show
            // a stale waveform/transcript next time it appears.
            KeyboardBridge.clearLiveStreams()
        }

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
                Task { await RecordingCoordinator.shared.forceEndBackgroundTask() }
            }
        }
        self.bgTaskId = taskId
        await TranscriptionStatus.shared.event("Triggered")
        await setUIRecording(true)
        let activityOK = await MainActor.run { ShhhcribbleActivityManager.shared.start() }
        if !activityOK {
            await TranscriptionStatus.shared.event("Live Activity unavailable — continuing without it")
        }
        // (defer block was here pre-fix; hoisted to top — see Fix B comment.)

        async let modelReady: Void = TextEngine.shared.ensureLoaded()

        try Task.checkCancellation()

        // Bring the mic up. `AudioInput.start` returns an AsyncStream that
        // we consume directly with for-await; teardown happens when
        // `stopRecording` / `cancelRecording` call `AudioInput.stop()` /
        // `AudioInput.cancel()` which finish the stream.
        let stream: AsyncStream<AVAudioPCMBuffer>
        do {
            // Throttle App Group writes for the keyboard pill's audio bars
            // to ~10 Hz. AudioInput delivers level callbacks at ~20 Hz; we
            // publish every callback to TranscriptionStatus (in-process,
            // free) but only every-other-tick to KeyboardBridge (cross-
            // process, UserDefaults round-trip).
            var lastKeyboardLevelWriteAt = Date.distantPast
            stream = try AudioInput.shared.start(onLevel: { level in
                Task { @MainActor in
                    TranscriptionStatus.shared.audioLevel = Double(level)
                    let now = Date()
                    if now.timeIntervalSince(lastKeyboardLevelWriteAt) >= 0.1 {
                        lastKeyboardLevelWriteAt = now
                        KeyboardBridge.writeLiveAudioLevel(Double(level))
                    }
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
                await RecordingCoordinator.shared.performLiveSnapshot()
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

        let finalised = await TextEngine.shared.finalize()
        // Fallback: if the post-stop final TDT pass produced a shorter
        // result than the last live snapshot, the tail buffer was likely
        // too short for the decoder to emit confident tokens and trimmed
        // a real sentence. Keep whichever is longer (length, not lexical)
        // so we never regress on what the user saw in the live overlay.
        let liveSnap = await MainActor.run { TranscriptionStatus.shared.partialSnippet }
        let transcript: String
        if liveSnap.count > finalised.count {
            transcript = liveSnap
            await TranscriptionStatus.shared.event("Final shorter than live (\(finalised.count) < \(liveSnap.count)) — using live snapshot")
        } else {
            transcript = finalised
        }
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
            // Pipe the partial to the App Group so the keyboard pill's
            // live-transcript text can render in real time. Bounded to
            // the last 120 chars — the keyboard only shows a single
            // line of trailing text.
            KeyboardBridge.writeLivePartial(String(snippet.suffix(120)))
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
