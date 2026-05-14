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

enum AsrMode: String, CaseIterable, Sendable {
    case streaming
    case tdt

    var displayName: String {
        switch self {
        case .streaming: return "Streaming (live, no punctuation)"
        case .tdt: return "Parakeet TDT v3 (punctuated, post-stop)"
        }
    }

    static var current: AsrMode {
        let raw = UserDefaults.standard.string(forKey: "asrMode") ?? AsrMode.streaming.rawValue
        return AsrMode(rawValue: raw) ?? .streaming
    }
}

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

    private var streamingManager: StreamingEouAsrManager?
    private var tdtManager: AsrManager?
    private var loadedMode: AsrMode?

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
    private var lastPartial = ""
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
        let desired = AsrMode.current
        if loadedMode == desired, (streamingManager != nil || tdtManager != nil) { return }
        if let loadTask {
            try await loadTask.value
            return
        }
        await TranscriptionStatus.shared.set(.loading)
        await TranscriptionStatus.shared.event("Loading \(desired.rawValue) model…")
        let task = Task { try await self.loadModel(mode: desired) }
        loadTask = task
        do {
            try await task.value
            loadTask = nil
            await TranscriptionStatus.shared.set(.ready)
            await TranscriptionStatus.shared.event("Model ready (\(desired.rawValue))")
        } catch {
            loadTask = nil
            await TranscriptionStatus.shared.set(.error(humaniseModelLoadError(error)))
            await TranscriptionStatus.shared.event("Model load failed: \(error)")
            throw error
        }
    }

    private func loadModel(mode: AsrMode) async throws {
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

        switch mode {
        case .streaming:
            let m = StreamingEouAsrManager(
                configuration: mlConfig,
                chunkSize: .ms320,
                eouDebounceMs: 999_999 // effectively disabled; overlay tap stops
            )
            try await m.loadModels(to: nil, configuration: nil, progressHandler: progressHandler)
            self.streamingManager = m
        case .tdt:
            let models = try await AsrModels.downloadAndLoad(
                configuration: mlConfig,
                version: .v3,
                progressHandler: progressHandler
            )
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            self.tdtManager = m
        }
        self.loadedMode = mode
    }

    private func unloadCurrent() async {
        if let m = streamingManager {
            await m.cleanup()
            streamingManager = nil
        }
        if let m = tdtManager {
            await m.cleanup()
            tdtManager = nil
        }
        loadedMode = nil
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
            } else {
                await TranscriptionStatus.shared.event("Stop: already stopping or not recording")
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

        var text = ""
        switch loadedMode {
        case .streaming:
            if let m = streamingManager {
                text = (try? await m.finish()) ?? ""
            }
            if text.isEmpty { text = lastPartial }
        case .tdt:
            if let m = tdtManager, !tdtBuffers.isEmpty {
                await TranscriptionStatus.shared.event("TDT transcribing \(tdtBuffers.count) buffers…")
                if let merged = Self.concatenate(buffers: tdtBuffers) {
                    var decoderState = TdtDecoderState.make()
                    do {
                        let result = try await m.transcribe(merged, decoderState: &decoderState)
                        text = result.text
                    } catch {
                        await TranscriptionStatus.shared.event("TDT error: \(error)")
                    }
                }
            }
        case .none:
            break
        }
        await TranscriptionStatus.shared.event("Finish returned: \"\(text.prefix(200))\"")

        resumeFinish(text)
    }

    /// Real abort — drop audio, skip transcription, skip SwiftData write,
    /// restore clipboard immediately. Invoked by the in-app Cancel button.
    func cancelRecording() async {
        guard recording, !stopRequested else {
            if !recording {
                pendingCancelBeforeStart = true
                await TranscriptionStatus.shared.event("Cancel deferred until recording starts")
            } else {
                await TranscriptionStatus.shared.event("Cancel: already stopping or not recording")
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
        lastPartial = ""

        // Resume the awaiter in recordAndTranscribe with empty text — the
        // `cancelled` flag is checked there to skip commit + SwiftData write.
        resumeFinish("")
    }

    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    func recordAndTranscribe(
        trigger: TriggerSource = .manual,
        appendingTo: UUID? = nil
    ) async throws {
        guard !recording else { return }

        // Claim the recording slot ATOMICALLY before any suspension point.
        // Without this, a Darwin-notification stop arriving during the
        // permission check sees `recording == false`, sets pendingStop,
        // and recordAndTranscribe bails before capturing any audio.
        recording = true
        stopRequested = false
        cancelled = false
        lastPartial = ""

        // Pre-flight mic permission. Surface a typed error UX in the
        // recording overlay if denied.
        let perm = await MainActor.run { AVAudioApplication.shared.recordPermission }
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
        } catch {
            recorder.stop()
            streamContinuation?.finish()
            streamContinuation = nil
            self.recorder = nil
            await notifyError(.modelLoadFailed(humaniseModelLoadError(error)))
            return
        }

        await TranscriptionStatus.shared.event("Recording (\(loadedMode?.rawValue ?? "?"))…")

        // The stream and engine are now live. If a stop or cancel was
        // requested during the pre-engine init window (Darwin race), tear
        // down NOW — at this point streamContinuation and recorder exist
        // and stopRecording() can do its normal job.
        if stopRequested {
            await TranscriptionStatus.shared.event("Honouring pre-engine stop request — tearing down now")
            recorder.stop()
            streamContinuation?.finish()
            streamContinuation = nil
            // Fall through to the streaming/tdt switch below so the existing
            // commit + cleanup path runs. The stop flag short-circuits any
            // further sample accumulation.
        }

        switch loadedMode {
        case .streaming:
            guard let manager = streamingManager else {
                await abortRecording()
                return
            }
            await manager.setPartialCallback { partial in
                Task { await TranscriptionService.shared.handlePartial(partial) }
            }
            let feed = Task.detached {
                for await buffer in buffers {
                    do {
                        _ = try await manager.process(audioBuffer: buffer)
                    } catch {
                        await TranscriptionStatus.shared.event("process err: \(error)")
                    }
                }
            }
            self.feedTask = feed

        case .tdt:
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

        case .none:
            await abortRecording()
            return
        }

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
        if let m = streamingManager { await m.reset() }

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
            // Phase collapses to .idle via the defer block; the toast carries
            // the user feedback. No haptic, no clipboard write, no Note saved.
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
        guard !tdtBuffers.isEmpty else { return }
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
            let afterFiller = filterOn ? FillerWordFilter.filter(text) : text
            let filtered = SubstitutionPass.apply(afterFiller, rules: SubstitutionPass.currentRules())
            // In-app overlay gets the full transcript so the typewriter
            // can extend it smoothly. The Live Activity gets only a bounded
            // tail because widget update payloads are rate-limited and the
            // banner only renders one truncated line anyway.
            let liveActivitySnippet = String(text.suffix(200))
            await MainActor.run {
                if !filtered.isEmpty {
                    UIPasteboard.general.string = filtered
                }
                TranscriptionStatus.shared.partialSnippet = filtered
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

        // Event-driven trigger: whenever fresh audio lands and enough time
        // has elapsed since the last transcribe, kick one off. This catches
        // the tail of an utterance faster than the timer alone.
        let now = Date()
        if tdtLastLiveAt.map({ now.timeIntervalSince($0) >= Self.tdtLiveInterval }) ?? true {
            tdtLastLiveAt = now
            Task { await self.tdtLiveTranscribe() }
        }
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

    private func handlePartial(_ partial: String) async {
        guard !partial.isEmpty else { return }
        lastPartial = partial
        let liveActivitySnippet = String(partial.suffix(200))
        // Live pasteboard update: iOS silently drops pasteboard writes from
        // backgrounded apps, so we push the transcript during recording
        // while we're still foreground. By the time the user taps the back
        // pill, the clipboard already holds the latest transcript.
        let filterOn = UserDefaults.standard.object(forKey: "filterFillerWords") as? Bool ?? true
        let afterFiller = filterOn ? FillerWordFilter.filter(partial) : partial
        let filtered = SubstitutionPass.apply(afterFiller, rules: SubstitutionPass.currentRules())
        await MainActor.run {
            ShhhcribbleActivityManager.shared.update(snippet: liveActivitySnippet)
            TranscriptionStatus.shared.partialSnippet = filtered
            if !filtered.isEmpty {
                UIPasteboard.general.string = filtered
            }
        }
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
            // and inject via UITextDocumentProxy when the user switches
            // back to the host text field. Darwin notification wakes the
            // keyboard's observer immediately if it's still active; the
            // textDidChange / viewDidAppear fallback covers the case
            // where the keyboard was suspended.
            KeyboardBridge.writeTranscript(text)
            KeyboardBridge.postDarwin(KeyboardBridge.darwinTranscriptReady)
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
