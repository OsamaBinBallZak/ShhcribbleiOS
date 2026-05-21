import AVFoundation
import CoreML
import FluidAudio
import Foundation
import os

private let diagLog = Logger(subsystem: "com.shhhcribble.diag", category: "engine")

// Model status lives here — it's a transcription-engine concern, not a
// recording-lifecycle one. `RecordingPhase` / `RecordingError` stay next to
// `TranscriptionService` (the coordinator-in-disguise).
enum ModelStatus: Equatable {
    case notLoaded
    case loading
    case ready
    case error(String)
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

/// `TextEngine` is the pure transcription module: model lifecycle, VAD-driven
/// chunk rotation, the live-snapshot re-transcribe, the final stitched
/// transcribe on stop, and one-shot batch transcription. It takes
/// `AVAudioPCMBuffer`s in and produces `String`s out. It knows nothing about
/// the mic, SwiftData, the clipboard, or the App Group.
///
/// The interface is six methods: `ensureLoaded`, `reload`, `reset`, `feed`,
/// `liveSnapshot`, `finalize`, `discard`, plus the batch `transcribeOneShot`.
/// VAD lives here (not on the audio side) because chunk rotation is a
/// transcription concern — it bounds TDT memory by stitching committed
/// chunks. Keeping VAD inside the engine makes the upstream interface from
/// audio capture exactly one line: `engine.feed(buffer)`.
actor TextEngine {
    static let shared = TextEngine()

    // MARK: - Model state

    private var tdtManager: AsrManager?
    /// Voice Activity Detection — Silero-style neural classifier from
    /// FluidAudio, completely separate from ASR. Used to find natural
    /// chunk boundaries during long recordings so we can rotate the
    /// accumulated `tdtBuffers` before they OOM the process (~37 min
    /// caused an iOS jetsam pre-fix).
    private var vadManager: VadManager?
    /// Running state for VadManager.processStreamingChunk — accumulates
    /// model hidden state across chunks. Initialised per session in
    /// `reset()`, cleared on `discard()` / `reset()`.
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

    private var loadTask: Task<Void, Error>?

    // MARK: - Per-session state

    /// Transcripts of audio segments already committed earlier in this
    /// session. On rotation we transcribe + clear `tdtBuffers` then
    /// append the raw result here. The displayed live snapshot is
    /// `committedChunks.joined(" ") + " " + currentLivePartial`, all
    /// run through `applyVocabulary` for filler + substitution. On
    /// finalize, the remaining `tdtBuffers` are transcribed once and
    /// stitched with these.
    private var committedChunks: [String] = []
    /// Timestamp of the last successful chunk rotation, or session
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

    private var tdtBuffers: [AVAudioPCMBuffer] = []
    private var sessionStartedAt: Date?
    /// Reentrancy guard on `liveSnapshot` — overlapping TDT calls would
    /// queue up; we just skip if one is already in flight.
    private var snapshotRunning = false

    private init() {}

    // MARK: - Model lifecycle

    func ensureLoaded() async throws {
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

    /// Force-unload and reload. Caller is responsible for ensuring no
    /// recording is in flight (see `TranscriptionService.reloadModel`).
    func reload() async {
        await unloadCurrent()
        loadTask = nil
        await TranscriptionStatus.shared.set(.notLoaded)
        await TranscriptionStatus.shared.event("Unloaded")
        try? await ensureLoaded()
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

    // MARK: - Recording-session lifecycle

    /// Start a fresh session. Drops any leftover buffers + committed
    /// chunks, resets VAD streaming state, stamps the session start.
    /// Must be called before any `feed(_:)` calls.
    func reset() async {
        tdtBuffers.removeAll(keepingCapacity: true)
        committedChunks.removeAll(keepingCapacity: false)
        lastRotationAt = nil
        rotating = false
        sessionStartedAt = Date()
        await resetVadStream()
    }

    /// Append a captured audio buffer. Synchronous — caller can call
    /// this from a tight loop without awaiting on actor latency. The
    /// VAD inference is dispatched into Tasks once enough samples have
    /// accumulated, so this method never blocks on neural-net work.
    func feed(_ buffer: AVAudioPCMBuffer) {
        // Copy the buffer — taps reuse backing storage, so holding the
        // original reference would mutate under us.
        guard let copy = Self.copy(buffer: buffer) else { return }
        tdtBuffers.append(copy)

        // VAD: accumulate samples inline (cheap synchronous resample +
        // append, no actor hop), only spawn a Task when we have enough
        // samples for an actual VAD inference chunk. Cuts the per-buffer
        // actor reentries by ~2.5x and lets live snapshots get enough
        // actor time to run smoothly.
        if vadManager != nil {
            accumulateVADSamples(from: copy)
        }
    }

    /// Best-effort full transcript right now. Combines committed chunks
    /// + a live re-transcribe of the accumulated buffer, applies the
    /// vocabulary pass, returns the filtered text. Safe to call from a
    /// timer; overlapping calls short-circuit via `snapshotRunning`.
    /// May trigger a hard-cap chunk rotation as a side effect.
    func liveSnapshot() async -> String {
        await maybeHardCapRotate()
        if tdtBuffers.isEmpty {
            return committedSnapshot()
        }
        guard let m = tdtManager else { return committedSnapshot() }
        if snapshotRunning {
            // Another snapshot is in flight; return whatever was already
            // computed (committed-only). The next tick will catch up.
            return committedSnapshot()
        }
        snapshotRunning = true
        defer { snapshotRunning = false }

        let snapshot = tdtBuffers
        guard let merged = Self.concatenate(buffers: snapshot) else {
            return committedSnapshot()
        }
        var state = TdtDecoderState.make()
        do {
            let result = try await m.transcribe(merged, decoderState: &state)
            let text = result.text
            guard !text.isEmpty else { return committedSnapshot() }
            let combinedRaw: String
            if committedChunks.isEmpty {
                combinedRaw = text
            } else {
                // Combine RAW so filler-words straddling the chunk
                // boundary are caught uniformly by `applyVocabulary`.
                combinedRaw = committedChunks.joined(separator: " ") + " " + text
            }
            return applyVocabulary(combinedRaw)
        } catch {
            return committedSnapshot()
        }
    }

    private func committedSnapshot() -> String {
        guard !committedChunks.isEmpty else { return "" }
        return applyVocabulary(committedChunks.joined(separator: " "))
    }

    /// Final stitched transcribe — runs once at stop. Transcribes any
    /// remaining `tdtBuffers`, joins with the committed chunks, applies
    /// the vocabulary pass once, returns. Side-effect: clears the
    /// pending buffer (the session is over).
    func finalize() async -> String {
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
        let stitchedRaw: String
        if committedChunks.isEmpty {
            stitchedRaw = finalSegment
        } else {
            let trimmedFinal = finalSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            stitchedRaw = trimmedFinal.isEmpty
                ? committedChunks.joined(separator: " ")
                : committedChunks.joined(separator: " ") + " " + trimmedFinal
        }
        tdtBuffers.removeAll(keepingCapacity: false)
        let filtered = applyVocabulary(stitchedRaw)
        await TranscriptionStatus.shared.event("Finish returned: \"\(filtered.prefix(200))\" (\(committedChunks.count) chunks + final)")
        return filtered
    }

    /// Drop everything. Called on cancel — no transcript will be
    /// produced, the session is being aborted.
    func discard() {
        tdtBuffers.removeAll(keepingCapacity: false)
        committedChunks.removeAll(keepingCapacity: false)
        vadStreamState = nil
        vadPendingSamples.removeAll(keepingCapacity: false)
        lastRotationAt = nil
        rotating = false
    }

    // MARK: - Batch (Feedback feature)

    /// One-shot transcribe of an audio file. Loads the file with
    /// AVAudioFile, hands the buffer to TDT, returns the raw transcript
    /// (no vocabulary pass — feedback transcripts are kept verbatim so
    /// the reviewer sees what the user actually said, fillers and all).
    /// Used by the Feedback capture flow — it records via AVAudioRecorder
    /// (independent of our main pipeline) and then transcribes once on
    /// stop. Doesn't touch session state.
    func transcribeOneShot(audioFileURL: URL) async throws -> String {
        try await ensureLoaded()
        guard let m = tdtManager else {
            throw NSError(
                domain: "Shhhcribble.TranscribeOneShot",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Transcription engine not loaded"]
            )
        }
        let file = try AVAudioFile(forReading: audioFileURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(
                domain: "Shhhcribble.TranscribeOneShot",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate audio buffer"]
            )
        }
        try file.read(into: buffer)
        var decoderState = TdtDecoderState.make()
        let result = try await m.transcribe(buffer, decoderState: &decoderState)
        return result.text
    }

    // MARK: - Vocabulary

    /// Fuse the filler-word filter and substitution pass into a single
    /// call. Replaces three duplicated invocation sites in the old
    /// `TranscriptionService`. Ordering is filter-then-substitute so
    /// substitutions don't get stripped by the filler regex.
    private func applyVocabulary(_ text: String) -> String {
        let filterOn = UserDefaults.standard.object(forKey: "filterFillerWords") as? Bool ?? true
        let afterFiller = filterOn ? FillerWordFilter.filter(text) : text
        return SubstitutionPass.apply(afterFiller, rules: SubstitutionPass.currentRules())
    }

    // MARK: - VAD pipeline

    /// Reset VAD streaming state at the start of a new session. Called
    /// from `reset()` so each session starts from a clean VAD state
    /// machine (no leftover triggered=true from a prior session).
    private func resetVadStream() async {
        guard let vad = vadManager else {
            vadStreamState = nil
            vadPendingSamples.removeAll(keepingCapacity: false)
            return
        }
        vadStreamState = await vad.makeStreamState()
        vadPendingSamples.removeAll(keepingCapacity: false)
    }

    /// Synchronous half: resample the incoming buffer, append to the
    /// pending-samples accumulator, then drain as many full
    /// 4096-sample chunks as we have, spawning one Task per chunk for
    /// the actual VAD inference. Called inline from `feed(_:)` (already
    /// on the actor) so no extra actor hop.
    private func accumulateVADSamples(from buffer: AVAudioPCMBuffer) {
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
            Task { await self.processVADChunk(chunk) }
        }
    }

    /// Async half: run the actual `processStreamingChunk` inference,
    /// update the streaming state, log events, and trigger rotation on
    /// speechEnd. One Task per chunk (~4 Hz at 16 kHz), not per
    /// incoming buffer (~10 Hz).
    private func processVADChunk(_ chunk: [Float]) async {
        guard let vad = vadManager, var state = vadStreamState else { return }
        do {
            let result = try await vad.processStreamingChunk(chunk, state: state)
            state = result.state
            vadStreamState = state
            if let event = result.event {
                let kind = event.kind == .speechStart ? "speechStart" : "speechEnd"
                await TranscriptionStatus.shared.event("VAD \(kind) @ sample \(event.sampleIndex) p=\(String(format: "%.2f", result.probability))")
                if event.kind == .speechEnd {
                    await maybeRotateChunk(triggerSource: "vad-speechEnd")
                }
            }
        } catch {
            await TranscriptionStatus.shared.event("VAD process err: \(error.localizedDescription)")
        }
    }

    private func maybeHardCapRotate() async {
        let startedAt = lastRotationAt ?? sessionStartedAt
        guard let s = startedAt, !tdtBuffers.isEmpty else { return }
        if Date().timeIntervalSince(s) > Self.maxTimeWithoutRotation {
            await maybeRotateChunk(triggerSource: "hard-cap")
        }
    }

    /// Chunk rotation. Triggered by VAD speechEnd events (when
    /// `minTimeBetweenRotations` has elapsed) and by the time-based
    /// hard cap (`maxTimeWithoutRotation`). Snapshots the current
    /// `tdtBuffers`, transcribes via TDT, appends the RAW text to
    /// `committedChunks`, and clears the buffer. Reentrancy-guarded
    /// via `rotating`. Skips silently if no manager, no buffers, or
    /// already rotating.
    private func maybeRotateChunk(triggerSource: String) async {
        guard !rotating else { return }
        guard let m = tdtManager, !tdtBuffers.isEmpty else { return }
        let startedAt = lastRotationAt ?? sessionStartedAt ?? Date()
        let elapsed = Date().timeIntervalSince(startedAt)
        // For VAD-triggered, require minTimeBetweenRotations so we don't
        // fragment on every short pause. For the hard-cap path the
        // caller already verified elapsed > maxTimeWithoutRotation.
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
            // Store RAW (unfiltered). Display and finalize both run the
            // vocabulary pass over the joined committed chunks so the
            // filter behaves uniformly across boundaries and respects
            // the current toggle state if the user changes it mid-session.
            committedChunks.append(trimmed)
            let displayedSoFar = applyVocabulary(committedChunks.joined(separator: " "))
            await TranscriptionStatus.shared.event("Committed chunk: \"\(displayedSoFar.suffix(80))\"")
        }
        lastRotationAt = Date()
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
