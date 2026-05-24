import AVFoundation
import ShhhcribbleShared
import UIKit
import os

private let log = Logger(subsystem: "com.shhhcribble.diag", category: "audio-input")

/// `AudioInput` is the unified audio-capture module. It owns the global
/// `AVAudioSession`, the long-lived warm `AVAudioEngine` (playing silence
/// to keep iOS happy), the route-change observer, the interruption
/// observer, the per-recording tap, the audio-level RMS computation, the
/// staleness watchdog, and the warm-mode idle-expiry scheduler.
///
/// It replaces three previous files (`AudioSessionManager`, `AudioRecorder`,
/// `AudioInterruptionObserver`) with one coherent module. The motivation:
/// the three files all observed `AVAudioEngineConfigurationChange` and had
/// to agree on ordering (rebuild engine first, then reinstall tap), and
/// the warm-mode lifecycle was implicit. Folding them merges the
/// route-change handler into a single ordered sequence and makes the
/// warm-mode lifecycle explicit at one call site.
///
/// Threading: this is a `final class`, not an `actor`, because the tap
/// callback runs on a real-time audio thread and forcing it through an
/// actor's serial executor would add hop overhead at 10–20 Hz. All
/// lifecycle methods are expected to be called from the main thread or
/// from `Task { @MainActor in ... }` boundaries.
///
/// CLAUDE.md AirPods rules still apply: never `setVoiceProcessingEnabled`
/// for Bluetooth, per-callback buffer copy (not pre-sized), rebuild engine
/// on route change (not patch). All of those are preserved here.
final class AudioInput: @unchecked Sendable {
    static let shared = AudioInput()
    private init() {}

    // MARK: - Session + warm engine state

    private let session = AVAudioSession.sharedInstance()
    private var warmEngine: AVAudioEngine?
    private var silentPlayer: AVAudioPlayerNode?
    private var silentBuffer: AVAudioPCMBuffer?
    private(set) var warmModeActive = false
    private var routeChangeObserver: NSObjectProtocol?
    private var inputTapInstalled = false

    /// Pending warm-mode expiry task — restarted after each commit,
    /// cancelled when a new recording starts. nil if warm mode is set
    /// to "Always" or off.
    private var idleExpiryTask: Task<Void, Never>?

    /// Read the user's chosen idle duration from UserDefaults. Returns
    /// nil for "always" — no auto-expire. Defaults to 60 s on first
    /// launch.
    public static var configuredIdleDurationSec: Int? {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "warmModeAlways") { return nil }
        let raw = defaults.object(forKey: "warmModeDurationSec") as? Int
        return raw ?? 60
    }

    // MARK: - Per-recording state

    private var privateEngine: AVAudioEngine?
    private var streamContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var onLevel: (@Sendable (Float) -> Void)?
    private var isRecording = false
    private var smoothedLevel: Float = 0

    /// Watchdog state for the "audio device unavailable" indicator.
    /// AVAudioEngine can be running (no errors thrown) and yet deliver
    /// no buffers — most often when AirPods are held by another nearby
    /// device (e.g. Mac via Continuity audio). We poll every ~300 ms;
    /// if `lastBufferAt` is older than `audioStaleThreshold`, publish
    /// `audioDeviceUnavailable = true` to TranscriptionStatus so the
    /// recording overlay can render a "Waiting for audio…" banner.
    private var lastBufferAt: Date?
    private var recordingStartedAt: Date?
    private var watchdogTimer: Timer?
    private static let audioStaleThreshold: TimeInterval = 1.5

    // MARK: - Interruption observer state

    /// Set when a recording starts; cleared on stop. Interruptions
    /// arriving within `handoffGrace` of this timestamp are ignored —
    /// the typical case is the audio-session handoff right after Siri
    /// triggers our intent: Siri releases the mic, our session
    /// activates, and a transient `.began` interruption fires as the
    /// contexts swap. Treating that as a real interruption killed
    /// Siri-launched recordings after ~1 s. Real interruptions (phone
    /// calls, alarms) arrive well outside this window.
    private var interruptionGraceStart: Date?
    private let handoffGrace: TimeInterval = 1.5

    // MARK: - App-launch wiring

    /// Configures the session category. Called once at app launch.
    func configure() {
        do {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            // .playAndRecord + .measurement: speech-optimised input
            // (disables AGC for raw mic levels) plus the ability to
            // play silence on output to keep iOS happy.
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            print("[Shhhcribble] session category set: .playAndRecord/.measurement")
        } catch {
            print("[Shhhcribble] session configure failed: \(error.localizedDescription)")
        }
    }

    /// Register the interruption observer. Called once at app launch.
    func startObservingInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }

        let inLPM = ProcessInfo.processInfo.isLowPowerModeEnabled

        switch type {
        case .began:
            // iOS 17+ exposes the interruption reason so we can distinguish
            // a real interruption (phone call, alarm — `.default`) from
            // transients we shouldn't hard-stop on (mic muted by privacy
            // switch, route disconnected, app suspended by system). Screen-
            // lock in Low Power Mode posts a transient `.began` that
            // previously killed recordings — feedback #4 (2026-05-24).
            let reasonRaw = info[AVAudioSessionInterruptionReasonKey] as? UInt
            let reason = reasonRaw.flatMap { AVAudioSession.InterruptionReason(rawValue: $0) }
            let reasonDesc = reason.map { String(describing: $0) } ?? "unknown"

            if let started = interruptionGraceStart,
               Date().timeIntervalSince(started) < handoffGrace {
                log.notice("Audio interruption .began ignored (within Siri handoff grace, reason=\(reasonDesc, privacy: .public), LPM=\(inLPM, privacy: .public))")
                return
            }

            // Only hard-stop on `.default` (real call, alarm). Other
            // reasons get logged + ignored. If audio truly stops flowing
            // after a transient, the staleness watchdog will surface
            // `audioDeviceUnavailable` to the UI without killing the
            // session. Treating an unknown nil reason as `.default`
            // preserves prior behaviour for the pre-iOS-17 envelope —
            // we'd rather over-stop than miss a real phone-call.
            if let reason, reason != .default {
                log.notice("Audio interruption .began ignored (reason=\(reasonDesc, privacy: .public), LPM=\(inLPM, privacy: .public)) — not a real interruption")
                return
            }

            log.notice("Audio interruption .began — stopping (reason=\(reasonDesc, privacy: .public), LPM=\(inLPM, privacy: .public))")
            Task { await RecordingCoordinator.shared.stopRecording() }
        case .ended:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Warm-mode lifecycle

    /// Activates the session and starts the silent-player engine. After
    /// this returns, the app stays alive in background until something
    /// tears the warm engine down. Call from main thread (typically
    /// `ShhhcribbleApp.init` or the keyboard-pretrigger Settings toggle).
    func enterWarmMode() {
        guard !warmModeActive else { return }
        activateRetrying()
        startWarmEngine()
        observeRouteChanges()
        warmModeActive = true
        print("[Shhhcribble] entered warm mode (single engine, silent player)")
        // Arm the idle-expiry timer so URL-scheme-launched warm sessions
        // (Universal Link / custom scheme cold-start path) actually expire
        // after the configured duration. Without this, entering warm mode
        // outside of a recording flow left the engine warm forever —
        // orange mic indicator never cleared. No-op when "Always" is set.
        scheduleIdleExpiry()
    }

    func exitWarmMode() {
        guard warmModeActive else { return }
        idleExpiryTask?.cancel()
        idleExpiryTask = nil
        unobserveRouteChanges()
        stopWarmEngine()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        warmModeActive = false
        print("[Shhhcribble] exited warm mode")
    }

    /// Schedule auto-exit after `configuredIdleDurationSec` seconds of
    /// inactivity. Called after each finalised recording. Cancelled when
    /// a new recording starts (via `cancelIdleExpiry`).
    func scheduleIdleExpiry() {
        idleExpiryTask?.cancel()
        guard warmModeActive,
              let duration = Self.configuredIdleDurationSec else {
            // "Always" mode or warm mode off — no expiry.
            return
        }
        print("[Shhhcribble] scheduling warm-mode idle expiry in \(duration)s")
        idleExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled,
                  let self,
                  self.warmModeActive else { return }
            // Don't exit if a recording happens to be active right now —
            // the recording's commit will reschedule us. Use the bridge
            // since TranscriptionStatus lives in the main module.
            if KeyboardBridge.isRecordingActive {
                print("[Shhhcribble] idle expiry fired but recording active — deferring")
                self.scheduleIdleExpiry()
                return
            }
            print("[Shhhcribble] warm-mode idle expiry firing")
            self.exitWarmMode()
        }
    }

    func cancelIdleExpiry() {
        idleExpiryTask?.cancel()
        idleExpiryTask = nil
    }

    // MARK: - Recording session

    /// Start a recording. Returns an `AsyncStream` of buffers + delivers
    /// audio levels to `onLevel`. Throws if the engine can't be brought
    /// up. Pair with exactly one `stop()` or `cancel()` call. The stream
    /// finishes when either of those is called.
    func start(onLevel: @escaping @Sendable (Float) -> Void) throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !isRecording else {
            // Already recording — return an immediately-finished stream
            // so the caller's for-await loop exits cleanly. A second
            // recording attempt is a caller bug.
            return AsyncStream { $0.finish() }
        }

        self.onLevel = onLevel
        self.smoothedLevel = 0

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        self.streamContinuation = continuation

        // Two paths: warm-engine tap, or private one-off engine. Warm
        // mode is the keyboard-ready setup — engine is already running,
        // we just attach a tap. Warm mode off (user opted out in
        // Settings) means we own a fresh engine for this recording per
        // Hendri's original AirPods rule.
        do {
            if !warmModeActive {
                configure()
                activateRetrying()
                try installPrivateEngine()
            } else {
                // Warm engine might have transiently quiesced between
                // `enterWarmMode` and now (observed on the keyboard
                // cold-start path — OS route-change fires after our
                // session activation, engine is briefly not running,
                // and our 200ms delayed route-change handler hasn't
                // restarted it yet). Defensive: ensure the engine is
                // running before installing the tap, restarting or
                // rebuilding as needed.
                if warmEngine == nil {
                    log.notice("AudioInput.start: warm engine missing, rebuilding")
                    startWarmEngine()
                } else if let engine = warmEngine, !engine.isRunning {
                    log.notice("AudioInput.start: warm engine not running, restarting")
                    do {
                        try engine.start()
                    } catch {
                        log.error("AudioInput.start: engine.start() retry failed: \(String(describing: error), privacy: .public) — rebuilding")
                        stopWarmEngine()
                        startWarmEngine()
                    }
                }
                try installSharedTap()
            }
        } catch {
            continuation.finish()
            self.streamContinuation = nil
            self.onLevel = nil
            throw error
        }

        observeRouteChanges()

        // Recording-active flag for the keyboard extension so its mic
        // button can switch to "Stop" mode while the user is in another
        // app.
        KeyboardBridge.setRecordingActive(true)

        // Watchdog: poll every 300 ms, publish `audioDeviceUnavailable`
        // when no buffers have arrived for `audioStaleThreshold` seconds.
        recordingStartedAt = Date()
        lastBufferAt = nil
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkAudioStaleness()
        }
        Task { @MainActor in
            TranscriptionStatus.shared.audioDeviceUnavailable = false
        }

        // Interruption observer: arm the grace window so Siri-handoff
        // transients don't kill the recording.
        interruptionGraceStart = Date()

        isRecording = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Diag: log LPM state at recording start so field repros of the
        // "screen-off in LPM stops recording" class of bug (feedback #4)
        // are diagnosable from idevicesyslog without needing a tethered
        // device.
        log.notice("Recording started (LPM=\(ProcessInfo.processInfo.isLowPowerModeEnabled, privacy: .public))")

        return stream
    }

    /// Graceful stop — finishes the stream after letting the audio system
    /// drain any in-flight buffer.
    func stop() {
        guard isRecording else { return }
        teardownRecording()
    }

    /// Immediate teardown — discards in-flight buffers, finishes the
    /// stream. Functionally identical to `stop()` at this level; the
    /// semantic split matters in the caller (commit-vs-skip-commit).
    func cancel() {
        guard isRecording else { return }
        teardownRecording()
    }

    private func teardownRecording() {
        if warmModeActive {
            removeInputTap()
        } else {
            privateEngine?.inputNode.removeTap(onBus: 0)
            privateEngine?.stop()
            privateEngine = nil
        }
        isRecording = false
        onLevel = nil
        smoothedLevel = 0

        watchdogTimer?.invalidate()
        watchdogTimer = nil
        lastBufferAt = nil
        recordingStartedAt = nil
        Task { @MainActor in
            TranscriptionStatus.shared.audioDeviceUnavailable = false
        }

        interruptionGraceStart = nil
        KeyboardBridge.setRecordingActive(false)

        streamContinuation?.finish()
        streamContinuation = nil
    }

    private func checkAudioStaleness() {
        guard isRecording else { return }
        let referenceTime = lastBufferAt ?? recordingStartedAt ?? Date()
        let staleFor = Date().timeIntervalSince(referenceTime)
        let isUnavailable = staleFor > Self.audioStaleThreshold
        Task { @MainActor in
            if TranscriptionStatus.shared.audioDeviceUnavailable != isUnavailable {
                TranscriptionStatus.shared.audioDeviceUnavailable = isUnavailable
            }
        }
    }

    // MARK: - Tap installation

    private func installSharedTap() throws {
        guard let engine = warmEngine, engine.isRunning else {
            print("[Shhhcribble] installSharedTap FAILED: warm engine not running")
            throw NSError(
                domain: "Shhhcribble.AudioInput",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Warm engine not running"]
            )
        }
        if inputTapInstalled {
            print("[Shhhcribble] installSharedTap: tap already installed, removing first")
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        print("[Shhhcribble] installSharedTap: format sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "Shhhcribble.AudioInput",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Input format invalid"]
            )
        }
        var bufferCount = 0
        engine.inputNode.installTap(onBus: 0, bufferSize: 0, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            bufferCount += 1
            if bufferCount == 1 || bufferCount == 10 {
                print("[Shhhcribble] AudioInput (shared) buffer #\(bufferCount) frameLength=\(buffer.frameLength)")
            }
            self.handleBuffer(buffer)
        }
        inputTapInstalled = true
    }

    private func installPrivateEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        print("[Shhhcribble] AudioInput (private) input format: sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
        var bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 0, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            bufferCount += 1
            if bufferCount == 1 || bufferCount == 10 {
                print("[Shhhcribble] AudioInput (private) buffer #\(bufferCount) frameLength=\(buffer.frameLength)")
            }
            self.handleBuffer(buffer)
        }
        try engine.start()
        self.privateEngine = engine
    }

    private func removeInputTap() {
        guard let engine = warmEngine, inputTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    // MARK: - Buffer handling

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        // Mark this buffer's arrival for the staleness watchdog. The
        // poll loop will clear `audioDeviceUnavailable` on its next
        // tick now that lastBufferAt is fresh.
        lastBufferAt = Date()
        // RMS for the audio level visualiser.
        if let ch = buffer.floatChannelData?[0] {
            let count = Int(buffer.frameLength)
            if count > 0 {
                var sum: Float = 0
                for i in 0..<count { sum += ch[i] * ch[i] }
                let rms = (sum / Float(count)).squareRoot()
                let scaled = min(1.0, rms * 12.0)
                self.smoothedLevel = max(scaled, self.smoothedLevel * 0.78)
                self.onLevel?(self.smoothedLevel)
            }
        }
        if let copy = Self.copyBuffer(buffer) {
            // Yield to the stream. AsyncStream serialises this safely
            // even though we're calling from the real-time audio thread.
            streamContinuation?.yield(copy)
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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

    // MARK: - Session activation

    private func activateRetrying() {
        do {
            try session.setActive(true, options: [])
            print("[Shhhcribble] session activated successfully")
        } catch {
            print("[Shhhcribble] session activate FAILED: \(error.localizedDescription)")
            Thread.sleep(forTimeInterval: 0.3)
            do {
                try session.setActive(true, options: [])
                print("[Shhhcribble] session activate succeeded on retry")
            } catch {
                print("[Shhhcribble] session activate retry FAILED: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Warm engine lifecycle

    private func startWarmEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = engine.outputNode.inputFormat(forBus: 0)

        // Defensive: if the audio route is in a transient state, the
        // format can be 0/0 and downstream `engine.connect` / `engine.start`
        // will raise NSException (which we can't catch). Bail; the next
        // route-change notification will re-attempt with a valid format.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log.notice("startWarmEngine: invalid format (sr=\(format.sampleRate), ch=\(format.channelCount)) — skipping rebuild, will retry on next route-change")
            return
        }

        let frameCount = AVAudioFrameCount(format.sampleRate * 0.2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            print("[Shhhcribble] startWarmEngine FAILED: could not allocate silent buffer")
            return
        }
        buffer.frameLength = frameCount

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.0

        // Touch the inputNode to ensure the engine binds it (some iOS
        // versions defer binding until the node is referenced).
        _ = engine.inputNode

        do {
            try engine.start()
            player.play()
            scheduleSilentLoop(player: player, buffer: buffer)
            self.warmEngine = engine
            self.silentPlayer = player
            self.silentBuffer = buffer
            print("[Shhhcribble] warm engine started")
        } catch {
            print("[Shhhcribble] warm engine start FAILED: \(error.localizedDescription)")
        }
    }

    private func scheduleSilentLoop(player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self, weak player] in
            guard let player else { return }
            DispatchQueue.main.async {
                guard let self, self.warmEngine?.isRunning == true else { return }
                self.scheduleSilentLoop(player: player, buffer: buffer)
            }
        }
    }

    private func stopWarmEngine() {
        if inputTapInstalled {
            warmEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        silentPlayer?.stop()
        warmEngine?.stop()
        silentPlayer = nil
        silentBuffer = nil
        warmEngine = nil
    }

    // MARK: - Route change handling (AirPods etc.)

    private func observeRouteChanges() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleRouteChange()
        }
    }

    private func unobserveRouteChanges() {
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            routeChangeObserver = nil
        }
    }

    /// Single ordered handler: rebuild warm engine (if any), then
    /// reinstall recording tap (if currently recording). 200ms delay
    /// before any work happens — without it, AVAudioEngine.start() can
    /// raise NSException with `IsFormatSampleRateAndChannelCountValid`
    /// because the input/output format is transiently invalid right
    /// after a route change. The original split-across-two-files design
    /// had the same delay inside AudioRecorder's reinstall closure;
    /// folding into one handler we keep it explicit here.
    private func handleRouteChange() {
        log.notice("AVAudioEngineConfigurationChange — rebuilding in 200ms")
        let wasRecording = isRecording

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }

            if self.warmModeActive {
                // Tear down warm engine + tap (if any), rebuild fresh.
                self.stopWarmEngine()
                self.activateRetrying()
                self.startWarmEngine()

                if wasRecording {
                    do {
                        try self.installSharedTap()
                        log.notice("shared tap reinstalled OK after route change")
                    } catch {
                        log.error("reinstall shared tap failed: \(String(describing: error), privacy: .public)")
                    }
                }
            } else if wasRecording {
                // Private-engine path: tear down + rebuild the recording
                // engine. No warm engine involved.
                self.privateEngine?.inputNode.removeTap(onBus: 0)
                self.privateEngine?.stop()
                self.privateEngine = nil
                do {
                    try self.installPrivateEngine()
                    log.notice("private engine rebuilt OK after route change")
                } catch {
                    log.error("private engine rebuild failed: \(String(describing: error), privacy: .public)")
                    self.streamContinuation?.finish()
                    self.streamContinuation = nil
                    self.isRecording = false
                }
            }
        }
    }
}
