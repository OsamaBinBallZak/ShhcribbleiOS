import AVFoundation
import Combine
import CoreML
import FluidAudio
import Foundation
import ShhhcribbleShared
import UIKit
import os

private let diagLog = Logger(subsystem: "com.shhhcribble.diag", category: "service")

enum ModelStatus: Equatable {
    case notLoaded
    case loading
    case ready
    case error(String)
}

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

// Map raw `Error` instances to short, user-readable copy. The default
// `String(describing: error)` dumps the entire NSError userInfo blob,
// which is unreadable in the Settings status row and the recording
// overlay error card. Most failures here are network errors from the
// HuggingFace download of the TDT model on first use.
func humaniseModelLoadError(_ error: Error) -> String {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed:
            return "No internet connection. Parakeet TDT v3 needs a one-time download (~494 MB) on first use."
        case NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorResourceUnavailable:
            return "Couldn't reach the model download server. Try again in a moment."
        default:
            return "Network error: \(error.localizedDescription)"
        }
    }
    if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
        return "Not enough free space to download the model (~494 MB needed)."
    }
    return error.localizedDescription
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

actor TranscriptionService {
    static let shared = TranscriptionService()

    private var tdtManager: AsrManager?
    /// Voice Activity Detection — Silero-style neural classifier from
    /// FluidAudio, completely separate from ASR. Used to find natural
    /// chunk boundaries during long recordings so we can rotate the
    /// accumulated `tdtBuffers` before they OOM the process (~37 min
    /// caused an iOS jetsam pre-fix). Step A loads. Step B (current)
    /// runs the streaming chunk processor in parallel with TDT
    /// accumulation and logs speech-start/end events. Step C will
    /// use those events to rotate the buffer.
    private var vadManager: VadManager?
    /// Running state for VadManager.processStreamingChunk — accumulates
    /// model hidden state across chunks. Initialised per recording in
    /// performRecording, cleared on stop/cancel.
    private var vadStreamState: VadStreamState?
    /// Pending 16 kHz mono Float samples not yet processed by VAD.
    /// VadManager wants exact 4096-sample chunks (~256 ms at 16 kHz);
    /// our incoming buffers come in ~100 ms 24 kHz units, so we
    /// resample + buffer until we have enough for one chunk.
    private var vadPendingSamples: [Float] = []
    /// FluidAudio's public resampler. Default-initialised it targets
    /// 16 kHz mono Float32 — exactly what VAD wants.
    private let vadResampler = AudioConverter()
    private static let vadChunkSize = 4096

    // MARK: - Chunked transcription (Step C)

    /// Transcripts of audio segments already committed earlier in this
    /// recording. On rotation we transcribe + clear `tdtBuffers` then
    /// append the result here. The displayed partial is
    /// `committedChunks.joined(" ") + " " + currentLivePartial`. On
    /// stop the final transcribe runs over the remaining `tdtBuffers`
    /// and is appended to this array before commit.
    private var committedChunks: [String] = []
    /// Timestamp of the last successful chunk rotation, or recording
    /// start if no rotation yet. Used to gate rotation triggers so
    /// every short utterance ending doesn't fragment the transcript.
    private var lastRotationAt: Date?
    /// Reentrancy guard. Rotation transcribe + buffer clear must run
    /// atomically — if a second VAD speechEnd fires while we're
    /// mid-rotation, ignore it.
    private var rotating = false
    /// Minimum elapsed time since last rotation before a VAD
    /// speechEnd is allowed to trigger a new rotation. Without this,
    /// every short pause would create a tiny chunk. 30 s gives the
    /// model meaningful context.
    private static let minTimeBetweenRotations: TimeInterval = 30
    /// Forced rotation deadline. If the user has talked continuously
    /// for this long without a clean VAD-detected pause, force a
    /// rotation anyway to keep memory bounded.
    private static let maxTimeWithoutRotation: TimeInterval = 90

    private var recorder: AudioRecorder?
    private var loadTask: Task<Void, Error>?
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
    /// state and the normal continuation-based stop path is stuck. Per
    /// research agent #3 (see SPRINT5_REPORT.md): flag-based cooperative
    /// cancel only fires at await boundaries we remember to check; a
    /// Task cancel + `Task.checkCancellation()` at every phase boundary
    /// is the idiomatic Swift pattern. We run both in parallel — the
    /// continuation handles the happy path, Task.cancel() is recovery.
    private var recordingTask: Task<Void, Error>?

    private var feedTask: Task<Void, Never>?
    private var tdtLiveTask: Task<Void, Never>?
    private var tdtLiveRunning = false
    private var tdtLastLiveAt: Date?
    private var recordingStartedAt: Date?
    private var currentTrigger: TriggerSource = .manual
    /// When non-nil, `commit` appends the transcript to the existing note with
    /// this id instead of inserting a new one. Set at the start of
    /// `recordAndTranscribe` and cleared on every exit path.
    private var appendTargetId: UUID?
    private static let tdtLiveInterval: TimeInterval = 0.7
    private var streamContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var tdtBuffers: [AVAudioPCMBuffer] = []

    private var finishContinuation: CheckedContinuation<String, Never>?

    private init() {}

    var isRecording: Bool { recording }

    private func resumeFinish(_ value: String) {
        guard let cont = finishContinuation else { return }
        finishContinuation = nil
        cont.resume(returning: value)
    }

    func ensureModelLoaded() async throws {
        if tdtManager != nil { return }
        if let loadTask {
            try await loadTask.value
            return
        }
        await TranscriptionStatus.shared.set(.loading)
        await TranscriptionStatus.shared.event("Loading Parakeet TDT v3…")
        let task = Task { try await self.loadModel() }
        loadTask = task
        do {
            try await task.value
            loadTask = nil
            await TranscriptionStatus.shared.set(.ready)
            await TranscriptionStatus.shared.event("Model ready")
        } catch {
            loadTask = nil
            await TranscriptionStatus.shared.set(.error(humaniseModelLoadError(error)))
            await TranscriptionStatus.shared.event("Model load failed: \(error)")
            throw error
        }
    }

    private func loadModel() async throws {
        let mlConfig = MLModelConfiguration()
        let useANE = UserDefaults.standard.object(forKey: "useANE") as? Bool ?? true
        mlConfig.computeUnits = useANE ? .cpuAndNeuralEngine : .cpuOnly

        await unloadCurrent()

        // Publish download fraction during the .downloading phase; reset to
        // nil for listing/compiling and on completion, so the play-button ring
        // only shows real byte transfer.
        let progressHandler: DownloadUtils.ProgressHandler = { progress in
            Task { @MainActor in
                if case .downloading = progress.phase {
                    TranscriptionStatus.shared.modelDownloadProgress = progress.fractionCompleted
                } else {
                    TranscriptionStatus.shared.modelDownloadProgress = nil
                }
            }
        }
        defer {
            Task { @MainActor in
                TranscriptionStatus.shared.modelDownloadProgress = nil
            }
        }

        let models = try await AsrModels.downloadAndLoad(
            configuration: mlConfig,
            version: .v3,
            progressHandler: progressHandler
        )
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        self.tdtManager = m

        // VAD load. Small model (~1-3 MB) used for silence-based chunk
        // boundary detection during long recordings. Failure to load is
        // non-fatal — chunked-transcribe falls back to a hard time cap
        // if vadManager stays nil.
        do {
            let vad = try await VadManager(progressHandler: nil)
            self.vadManager = vad
            await TranscriptionStatus.shared.event("VAD ready")
        } catch {
            await TranscriptionStatus.shared.event("VAD load failed (non-fatal): \(error.localizedDescription)")
            self.vadManager = nil
        }
    }

    private func unloadCurrent() async {
        if let m = tdtManager {
            await m.cleanup()
            tdtManager = nil
        }
        // VadManager has no explicit cleanup; just drop the reference.
        vadManager = nil
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

        await unloadCurrent()
        loadTask = nil
        await TranscriptionStatus.shared.set(.notLoaded)
        await TranscriptionStatus.shared.event("Unloaded")
        try? await ensureModelLoaded()
    }

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
        AudioInterruptionObserver.shared.recordingDidStop()
        await TranscriptionStatus.shared.event("Manual stop")

        recorder?.stop()
        streamContinuation?.finish()
        tdtLiveTask?.cancel()

        if let feedTask {
            _ = await feedTask.value
        }
        await TranscriptionStatus.shared.event("Drained buffers")

        var finalSegment = ""
        if let m = tdtManager, !tdtBuffers.isEmpty {
            await TranscriptionStatus.shared.event("TDT transcribing \(tdtBuffers.count) buffers…")
            if let merged = Self.concatenate(buffers: tdtBuffers) {
                var decoderState = TdtDecoderState.make()
                do {
                    let result = try await m.transcribe(merged, decoderState: &decoderState)
                    finalSegment = result.text
                } catch {
                    await TranscriptionStatus.shared.event("TDT error: \(error)")
                }
            }
        }
        // Step C: stitch the committed chunks (already filtered) with the
        // newly-transcribed final segment (still raw). Filtering of the
        // final segment happens downstream in performRecording's filter
        // pass, so we leave it raw here and let that pass apply uniformly.
        // The committed chunks were already filter+substitution-passed at
        // rotation time, so re-running the filter on them would be a
        // double-filter — instead, we concatenate as-is.
        let stitched: String
        if committedChunks.isEmpty {
            stitched = finalSegment
        } else {
            let trimmedFinal = finalSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            stitched = trimmedFinal.isEmpty
                ? committedChunks.joined(separator: " ")
                : committedChunks.joined(separator: " ") + " " + trimmedFinal
        }
        await TranscriptionStatus.shared.event("Finish returned: \"\(stitched.prefix(200))\" (\(committedChunks.count) chunks + final)")

        resumeFinish(stitched)
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
        AudioInterruptionObserver.shared.recordingDidStop()
        await TranscriptionStatus.shared.event("Cancel")

        recorder?.stop()
        streamContinuation?.finish()
        tdtLiveTask?.cancel()
        feedTask?.cancel()

        tdtBuffers.removeAll(keepingCapacity: false)
        vadStreamState = nil
        vadPendingSamples.removeAll(keepingCapacity: false)
        // Step C: drop any in-progress rotation state too.
        committedChunks.removeAll(keepingCapacity: false)
        lastRotationAt = nil
        rotating = false

        // Resume the awaiter in recordAndTranscribe with empty text — the
        // `cancelled` flag is checked there to skip commit + SwiftData write.
        resumeFinish("")
    }

    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    /// Public entry point. Wraps the body in an internal `Task` so callers
    /// of `stopRecording` / `cancelRecording` can hard-cancel via
    /// `Task.cancel()` in addition to the existing continuation-based
    /// stop. The body throws `CancellationError` at any `Task.checkCancellation()`
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
        tdtBuffers.removeAll(keepingCapacity: true)
        tdtLastLiveAt = nil
        recordingStartedAt = Date()
        await resetVadStream()
        // Step C: rotation state — fresh per recording.
        committedChunks.removeAll(keepingCapacity: false)
        lastRotationAt = nil
        rotating = false
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
        AudioInterruptionObserver.shared.recordingDidStart()

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
            AudioSessionManager.shared.cancelIdleExpiry()
        }

        // No clipboard snapshot/restore in the in-app flow — the user's
        // clipboard gets replaced by the transcript and stays there. Restore
        // is reserved for the Sprint 5 keyboard-extension autopaste path,
        // where the keyboard injects text and then needs to put the original
        // clipboard back. ClipboardService.swift exists for that.

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
        // No more pause/resume of the warm engine — the single-engine
        // design has AudioRecorder install a tap on the same engine
        // that's playing silence, so they coexist by design.
        await setUIRecording(true)
        let activityOK = await MainActor.run { ShhhcribbleActivityManager.shared.start() }
        if !activityOK {
            await TranscriptionStatus.shared.event("Live Activity unavailable — continuing without it")
        }
        defer {
            recording = false
            stopRequested = false
            tdtBuffers.removeAll()
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

        async let modelReady: Void = ensureModelLoaded()

        try Task.checkCancellation()

        let recorder = AudioRecorder()
        self.recorder = recorder

        let buffers = AsyncStream<AVAudioPCMBuffer>(bufferingPolicy: .unbounded) { continuation in
            self.streamContinuation = continuation
            do {
                try recorder.start(
                    onBuffer: { buffer in
                        continuation.yield(buffer)
                    },
                    onLevel: { level in
                        // Hop to MainActor to update the published level.
                        // ~20 Hz writes — fine for SwiftUI.
                        Task { @MainActor in
                            TranscriptionStatus.shared.audioLevel = Double(level)
                        }
                    }
                )
            } catch {
                continuation.finish()
            }
        }

        do {
            try await modelReady
        } catch is CancellationError {
            recorder.stop()
            streamContinuation?.finish()
            streamContinuation = nil
            self.recorder = nil
            throw CancellationError()
        } catch {
            recorder.stop()
            streamContinuation?.finish()
            streamContinuation = nil
            self.recorder = nil
            await notifyError(.modelLoadFailed(humaniseModelLoadError(error)))
            return
        }

        try Task.checkCancellation()

        await TranscriptionStatus.shared.event("Recording…")

        // The stream and engine are now live. If a stop or cancel was
        // requested during the pre-engine init window (Darwin race), tear
        // down NOW — at this point streamContinuation and recorder exist
        // and stopRecording() can do its normal job.
        if stopRequested {
            await TranscriptionStatus.shared.event("Honouring pre-engine stop request — tearing down now")
            recorder.stop()
            streamContinuation?.finish()
            streamContinuation = nil
            // Fall through to the TDT setup below so the existing commit +
            // cleanup path runs. The stop flag short-circuits any further
            // sample accumulation.
        }

        guard tdtManager != nil else {
            await abortRecording()
            return
        }

        // Accumulate buffers; separately, re-transcribe every ~1.5s so
        // the clipboard stays fresh while the app is foreground. iOS
        // blocks pasteboard writes from backgrounded apps, so we can't
        // wait until after the user taps the back pill.
        await MainActor.run {
            TranscriptionStatus.shared.partialSnippet = "Recording…"
        }
        let feed = Task.detached {
            for await buffer in buffers {
                await TranscriptionService.shared.appendTdtBuffer(buffer)
            }
        }
        self.feedTask = feed

        // Safety-net timer in case the buffer-arrival trigger misses
        // (e.g. silence keeps the audio engine from delivering buffers).
        let live = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tdtLiveInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await TranscriptionService.shared.tdtLiveTranscribe()
            }
        }
        self.tdtLiveTask = live

        let transcript: String = await withCheckedContinuation { cont in
            self.finishContinuation = cont
        }

        recorder.stop()
        streamContinuation?.finish()
        streamContinuation = nil
        self.recorder = nil
        self.feedTask = nil
        self.tdtLiveTask?.cancel()
        self.tdtLiveTask = nil

        await TranscriptionStatus.shared.event("Got: \"\(transcript)\"")

        if cancelled {
            await TranscriptionStatus.shared.event("Cancelled — discarding transcript")
            await MainActor.run {
                TranscriptionStatus.shared.partialSnippet = ""
            }
            return
        }

        let filterOn = UserDefaults.standard.object(forKey: "filterFillerWords") as? Bool ?? true
        let afterFiller = filterOn ? FillerWordFilter.filter(transcript) : transcript
        let filtered = SubstitutionPass.apply(afterFiller, rules: SubstitutionPass.currentRules())
        guard !filtered.isEmpty else {
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
                AudioSessionManager.shared.scheduleIdleExpiry()
            }
            return
        }

        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let trigger = currentTrigger
        let target = appendTargetId
        await commit(filtered, duration: duration, trigger: trigger, appendingTo: target)
        await TranscriptionStatus.shared.event(target == nil ? "Copied to clipboard" : "Added to note")
        await maybeAutoBackground()
    }

    func forceEndBackgroundTask() async {
        await stopRecording()
    }

    /// Run TDT on the current accumulated buffer and push the result to the
    /// clipboard. Guarded so overlapping calls don't queue up.
    private func tdtLiveTranscribe() async {
        guard !stopRequested, !tdtLiveRunning, let m = tdtManager else { return }
        // Step C: hard-cap rotation check. If we've been recording too
        // long without a VAD-triggered rotation, force one now. Skip
        // if we have no buffers to transcribe (rare edge case).
        let startedAt = lastRotationAt ?? recordingStartedAt
        if let s = startedAt, !tdtBuffers.isEmpty,
           Date().timeIntervalSince(s) > Self.maxTimeWithoutRotation {
            await maybeRotateChunk(triggerSource: "hard-cap")
        }
        guard !tdtBuffers.isEmpty else {
            // After a rotation the live buffer is empty. Still update
            // the displayed partial to show the committed prefix.
            if !committedChunks.isEmpty {
                let filterOn = UserDefaults.standard.object(forKey: "filterFillerWords") as? Bool ?? true
                let joinedRaw = committedChunks.joined(separator: " ")
                let afterFiller = filterOn ? FillerWordFilter.filter(joinedRaw) : joinedRaw
                let displayed = SubstitutionPass.apply(afterFiller, rules: SubstitutionPass.currentRules())
                await MainActor.run {
                    TranscriptionStatus.shared.partialSnippet = displayed
                }
            }
            return
        }
        tdtLiveRunning = true
        defer { tdtLiveRunning = false }

        let snapshot = tdtBuffers
        guard let merged = Self.concatenate(buffers: snapshot) else { return }
        var state = TdtDecoderState.make()
        do {
            let result = try await m.transcribe(merged, decoderState: &state)
            let text = result.text
            guard !text.isEmpty else { return }
            let filterOn = UserDefaults.standard.object(forKey: "filterFillerWords") as? Bool ?? true
            // Step C: filter the FULL combined raw text (committed + live)
            // so filter passes work uniformly across the chunk boundary
            // — e.g. a filler word straddling the boundary still gets
            // caught. Committed is stored raw so this is safe.
            let combinedRaw: String
            if committedChunks.isEmpty {
                combinedRaw = text
            } else {
                combinedRaw = committedChunks.joined(separator: " ") + " " + text
            }
            let afterFiller = filterOn ? FillerWordFilter.filter(combinedRaw) : combinedRaw
            let displayed = SubstitutionPass.apply(afterFiller, rules: SubstitutionPass.currentRules())
            // In-app overlay gets the full transcript so the typewriter
            // can extend it smoothly. The Live Activity gets only a bounded
            // tail because widget update payloads are rate-limited and the
            // banner only renders one truncated line anyway.
            let liveActivitySnippet = String(displayed.suffix(200))
            await MainActor.run {
                if !displayed.isEmpty {
                    UIPasteboard.general.string = displayed
                }
                TranscriptionStatus.shared.partialSnippet = displayed
                ShhhcribbleActivityManager.shared.update(snippet: liveActivitySnippet)
            }
        } catch {
            // Best-effort — the final transcribe on stop will catch up.
        }
    }

    private func appendTdtBuffer(_ buffer: AVAudioPCMBuffer) {
        // Copy the buffer — the tap reuses backing storage, so holding the
        // original reference would mutate under us.
        guard let copy = Self.copy(buffer: buffer) else { return }
        tdtBuffers.append(copy)

        // Feed the same buffer to VAD in parallel. Step B: just log
        // speechStart/speechEnd events to verify the boundary detection
        // fires sensibly. Step C will use these events to rotate
        // tdtBuffers mid-recording.
        Task { await self.feedVAD(buffer: copy) }

        // Event-driven trigger: whenever fresh audio lands and enough time
        // has elapsed since the last transcribe, kick one off. This catches
        // the tail of an utterance faster than the timer alone.
        let now = Date()
        if tdtLastLiveAt.map({ now.timeIntervalSince($0) >= Self.tdtLiveInterval }) ?? true {
            tdtLastLiveAt = now
            Task { await self.tdtLiveTranscribe() }
        }
    }

    /// Resample incoming buffer to 16 kHz Float, accumulate, and feed
    /// to VadManager in 4096-sample chunks. Logs speechStart/speechEnd
    /// events via TranscriptionStatus.event. Failures are non-fatal
    /// (VAD is a polish feature, not on the critical recording path).
    private func feedVAD(buffer: AVAudioPCMBuffer) async {
        guard let vad = vadManager, var state = vadStreamState else { return }
        let samples: [Float]
        do {
            samples = try vadResampler.resampleBuffer(buffer)
        } catch {
            // Resample failed — skip this buffer for VAD, recording continues.
            return
        }
        vadPendingSamples.append(contentsOf: samples)
        while vadPendingSamples.count >= Self.vadChunkSize {
            let chunk = Array(vadPendingSamples.prefix(Self.vadChunkSize))
            vadPendingSamples.removeFirst(Self.vadChunkSize)
            do {
                let result = try await vad.processStreamingChunk(chunk, state: state)
                state = result.state
                if let event = result.event {
                    let kind = event.kind == .speechStart ? "speechStart" : "speechEnd"
                    await TranscriptionStatus.shared.event("VAD \(kind) @ sample \(event.sampleIndex) p=\(String(format: "%.2f", result.probability))")
                    if event.kind == .speechEnd {
                        await maybeRotateChunk(triggerSource: "vad-speechEnd")
                    }
                }
            } catch {
                await TranscriptionStatus.shared.event("VAD process err: \(error.localizedDescription)")
                break
            }
        }
        vadStreamState = state
    }

    /// Step C — chunk rotation. Triggered by VAD speechEnd events (when
    /// `minTimeBetweenRotations` has elapsed) and by the time-based
    /// hard cap (`maxTimeWithoutRotation`). Snapshots the current
    /// `tdtBuffers`, transcribes via TDT, applies the filler +
    /// substitution filters, appends to `committedChunks`, and clears
    /// the buffer. Reentrancy-guarded via `rotating`.
    ///
    /// Skips silently if no manager, no buffers, or already rotating.
    private func maybeRotateChunk(triggerSource: String) async {
        guard !rotating else { return }
        guard recording, !stopRequested, !cancelled else { return }
        guard let m = tdtManager, !tdtBuffers.isEmpty else { return }
        let startedAt = lastRotationAt ?? recordingStartedAt ?? Date()
        let elapsed = Date().timeIntervalSince(startedAt)
        // For VAD-triggered, require minTimeBetweenRotations so we don't
        // fragment on every short pause. For the hard-cap path
        // (triggerSource == "hard-cap") the caller already verified
        // elapsed > maxTimeWithoutRotation, so we skip the gate.
        if triggerSource != "hard-cap", elapsed < Self.minTimeBetweenRotations {
            return
        }
        rotating = true
        let snapshot = tdtBuffers
        tdtBuffers.removeAll(keepingCapacity: true)
        defer { rotating = false }

        await TranscriptionStatus.shared.event("Rotating chunk (\(triggerSource), \(snapshot.count) buffers, \(String(format: "%.1f", elapsed))s)")
        guard let merged = Self.concatenate(buffers: snapshot) else {
            // Couldn't merge — give up on this rotation, audio is lost.
            // Recording continues; next rotation will catch fresh buffers.
            return
        }
        var decoderState = TdtDecoderState.make()
        let raw: String
        do {
            let result = try await m.transcribe(merged, decoderState: &decoderState)
            raw = result.text
        } catch {
            await TranscriptionStatus.shared.event("Rotation TDT err: \(error.localizedDescription)")
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Store RAW (unfiltered) — performRecording's final filter
            // pass applies once to the stitched output. Storing raw
            // avoids double-filtering and keeps the filter behaviour
            // consistent if the user toggles filterFillerWords mid-
            // recording. Display still shows the filtered version
            // (see tdtLiveTranscribe + the MainActor block below).
            committedChunks.append(trimmed)
            // Refresh the displayed partial to include the new committed
            // text (filtered for display). Without this the user sees
            // the live preview suddenly become empty (tdtBuffers cleared)
            // then re-populate; with this the committed prefix carries
            // forward.
            let filterOn = UserDefaults.standard.object(forKey: "filterFillerWords") as? Bool ?? true
            let joinedRaw = committedChunks.joined(separator: " ")
            let afterFiller = filterOn ? FillerWordFilter.filter(joinedRaw) : joinedRaw
            let displayedSoFar = SubstitutionPass.apply(afterFiller, rules: SubstitutionPass.currentRules())
            await TranscriptionStatus.shared.event("Committed chunk: \"\(displayedSoFar.suffix(80))\"")
            await MainActor.run {
                TranscriptionStatus.shared.partialSnippet = displayedSoFar
            }
        }
        lastRotationAt = Date()
    }

    /// Reset VAD streaming state at the start of a new recording. Called
    /// from performRecording so each recording starts from a clean VAD
    /// state machine (no leftover triggered=true from a prior session).
    private func resetVadStream() async {
        guard let vad = vadManager else {
            vadStreamState = nil
            vadPendingSamples.removeAll(keepingCapacity: false)
            return
        }
        vadStreamState = await vad.makeStreamState()
        vadPendingSamples.removeAll(keepingCapacity: false)
    }

    private func abortRecording() async {
        recorder?.stop()
        streamContinuation?.finish()
        streamContinuation = nil
        recorder = nil
        await notifyError(.other("Recording failed to start."))
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
        AudioSessionManager.shared.scheduleIdleExpiry()
    }

    @MainActor
    private func notifyError(_ error: RecordingError) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        TranscriptionStatus.shared.partialSnippet = ""
        TranscriptionStatus.shared.launchedViaURL = false
        TranscriptionStatus.shared.setPhase(.error(error))
    }

    // MARK: - Buffer helpers

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dst = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        dst.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let out = dst.floatChannelData {
            for ch in 0..<channels {
                memcpy(out[ch], src[ch], frames * MemoryLayout<Float>.size)
            }
        }
        return dst
    }

    private static func concatenate(buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let format = first.format
        let total = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        out.frameLength = total
        let channels = Int(format.channelCount)
        var offset = 0
        for buf in buffers {
            let frames = Int(buf.frameLength)
            if let src = buf.floatChannelData, let dst = out.floatChannelData {
                for ch in 0..<channels {
                    memcpy(dst[ch] + offset, src[ch], frames * MemoryLayout<Float>.size)
                }
            }
            offset += frames
        }
        return out
    }
}
