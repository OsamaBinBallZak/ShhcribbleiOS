import AVFoundation
import ShhhcribbleShared
import UIKit
import os

private let audioLog = Logger(subsystem: "com.shhhcribble.diag", category: "audio")

/// Captures mic buffers by installing a tap on `AudioSessionManager`'s
/// shared warm engine. Does NOT own an engine of its own — the previous
/// two-engine design corrupted the input node format on iOS 26 (crashed
/// `installTap` with `IsFormatSampleRateAndChannelCountValid`).
///
/// Hendri's original rule of "fresh engine per recording for AirPods
/// route-change self-healing" is now satisfied by `AudioSessionManager`
/// rebuilding the warm engine on `AVAudioEngineConfigurationChange`.
final class AudioRecorder {
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onLevel: ((Float) -> Void)?
    private(set) var isRunning = false

    private var smoothedLevel: Float = 0
    private var routeChangeObserver: NSObjectProtocol?

    /// Watchdog state for the "audio device unavailable" indicator.
    /// AVAudioEngine can be running (no errors thrown) and yet deliver
    /// no buffers — most often when AirPods are held by another nearby
    /// device (e.g. Mac via Continuity audio). We poll every ~300 ms;
    /// if `lastBufferAt` is older than `audioStaleThreshold`, publish
    /// `audioDeviceUnavailable = true` to TranscriptionStatus so the
    /// recording overlay can render a "Waiting for audio…" banner.
    private var lastBufferAt: Date?
    private var startedAt: Date?
    private var watchdogTimer: Timer?
    private static let audioStaleThreshold: TimeInterval = 1.5

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping (Float) -> Void = { _ in }
    ) throws {
        guard !isRunning else { return }
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.smoothedLevel = 0

        // The session manager owns the engine + activation. If warm mode
        // is on, the engine is already running and we just need to attach
        // a tap. If warm mode is off, fall back to a one-off configure +
        // activate cycle — the old behaviour for in-app recording when
        // the keyboard pathway isn't in play.
        if !AudioSessionManager.shared.warmModeActive {
            AudioSessionManager.shared.configure()
            AudioSessionManager.shared.activate()
            // No warm engine to tap. We need a private engine for this
            // case. (Used for in-app foreground recording when the user
            // hasn't enabled "Keep keyboard ready".)
            try installPrivateEngine()
        } else {
            // Warm engine path — install tap on the shared engine.
            try installSharedTap()
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        // Tell the keyboard a recording is live so its mic button can
        // switch to "Stop" mode while the user is in another app.
        KeyboardBridge.setRecordingActive(true)

        // Staleness watchdog. Resets state, then polls every 300 ms.
        // Publishes `audioDeviceUnavailable` to TranscriptionStatus when
        // no buffers have arrived for `audioStaleThreshold` seconds.
        startedAt = Date()
        lastBufferAt = nil
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkAudioStaleness()
        }
        // Make sure stale flag starts false — user just tapped record,
        // no need to show "waiting" instantly.
        Task { @MainActor in
            TranscriptionStatus.shared.audioDeviceUnavailable = false
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func checkAudioStaleness() {
        guard isRunning else { return }
        let referenceTime = lastBufferAt ?? startedAt ?? Date()
        let staleFor = Date().timeIntervalSince(referenceTime)
        let isUnavailable = staleFor > Self.audioStaleThreshold
        Task { @MainActor in
            if TranscriptionStatus.shared.audioDeviceUnavailable != isUnavailable {
                TranscriptionStatus.shared.audioDeviceUnavailable = isUnavailable
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            routeChangeObserver = nil
        }
        if AudioSessionManager.shared.warmModeActive {
            AudioSessionManager.shared.removeInputTap()
        } else {
            privateEngine?.inputNode.removeTap(onBus: 0)
            privateEngine?.stop()
            privateEngine = nil
        }
        isRunning = false
        onBuffer = nil
        onLevel = nil
        smoothedLevel = 0

        watchdogTimer?.invalidate()
        watchdogTimer = nil
        lastBufferAt = nil
        startedAt = nil
        Task { @MainActor in
            TranscriptionStatus.shared.audioDeviceUnavailable = false
        }

        KeyboardBridge.setRecordingActive(false)
    }

    // MARK: - Private engine fallback (warm mode off)
    //
    // When warm mode is disabled the recorder owns its engine for a
    // single recording, recreated each time per Hendri's AirPods rule.

    private var privateEngine: AVAudioEngine?

    private func installPrivateEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        print("[Shhhcribble] AudioRecorder (private) input format: sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
        var bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 0, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            bufferCount += 1
            if bufferCount == 1 || bufferCount == 10 {
                print("[Shhhcribble] AudioRecorder (private) buffer #\(bufferCount) frameLength=\(buffer.frameLength)")
            }
            self.handleBuffer(buffer)
        }
        try engine.start()
        self.privateEngine = engine
        isRunning = true
    }

    private func installSharedTap() throws {
        var bufferCount = 0
        let ok = AudioSessionManager.shared.installInputTap { [weak self] buffer, _ in
            guard let self else { return }
            bufferCount += 1
            if bufferCount == 1 || bufferCount == 10 {
                print("[Shhhcribble] AudioRecorder (shared) buffer #\(bufferCount) frameLength=\(buffer.frameLength)")
            }
            self.handleBuffer(buffer)
        }
        guard ok else {
            throw NSError(
                domain: "Shhhcribble.AudioRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not install tap on warm engine"]
            )
        }
        isRunning = true
    }

    // MARK: - Buffer handling

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        // Mark this buffer's arrival for the staleness watchdog. The
        // poll loop will clear `audioDeviceUnavailable` on its next
        // tick now that lastBufferAt is fresh.
        lastBufferAt = Date()
        // RMS for the audio level visualizer.
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
            self.onBuffer?(copy)
        }
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        audioLog.notice("AVAudioEngineConfigurationChange — reinstalling tap")
        if AudioSessionManager.shared.warmModeActive {
            // Session manager rebuilds the engine on the same notification.
            // Wait briefly so the new engine is up, then reinstall the tap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.isRunning else { return }
                do {
                    try self.installSharedTap()
                } catch {
                    audioLog.error("reinstall shared tap failed: \(String(describing: error), privacy: .public)")
                }
            }
        } else {
            privateEngine?.inputNode.removeTap(onBus: 0)
            privateEngine?.stop()
            privateEngine = nil
            do {
                try installPrivateEngine()
                audioLog.notice("private engine rebuilt OK after route change")
            } catch {
                audioLog.error("private engine rebuild failed: \(String(describing: error), privacy: .public)")
                isRunning = false
            }
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
}
