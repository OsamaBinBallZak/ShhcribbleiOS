import AVFoundation
import UIKit
import os

private let audioLog = Logger(subsystem: "com.shhhcribble.diag", category: "audio")

final class AudioRecorder {
    private var engine = AVAudioEngine()
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onLevel: ((Float) -> Void)?
    private(set) var isRunning = false

    /// Smoothed RMS level kept between callbacks for the envelope follower.
    /// Attack is instantaneous (max of incoming or decayed prior); release
    /// is a per-buffer decay so the bars trail off during pauses.
    private var smoothedLevel: Float = 0

    private var routeChangeObserver: NSObjectProtocol?

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping (Float) -> Void = { _ in }
    ) throws {
        guard !isRunning else { return }
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.smoothedLevel = 0

        AudioSessionManager.shared.configure()
        AudioSessionManager.shared.activate()

        try installTapAndStart()

        // Observe mid-recording route changes (AirPods disconnect, Continuity
        // Mic swap, Bluetooth dropout). Per CLAUDE.md, the right response is
        // a fresh AVAudioEngine — surgically patching the existing one
        // deadlocks on AirPods. Already-captured samples are preserved by the
        // caller's accumulation buffers; the new tap continues feeding into
        // the same continuation.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func stop() {
        guard isRunning else { return }
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            routeChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        onBuffer = nil
        onLevel = nil
        smoothedLevel = 0
    }

    // MARK: - Internals

    private func installTapAndStart() throws {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        print("[Shhhcribble] AudioRecorder input format: sampleRate=\(format.sampleRate) channels=\(format.channelCount)")

        var bufferCount = 0
        // Buffer size 0 lets AVAudioEngine pick its natural delivery size.
        // Hardcoding (e.g. 2560) silently truncates trailing audio on AirPods
        // because they deliver variable-size stereo buffers; pre-sized taps
        // can clip the last frames of an utterance.
        inputNode.installTap(onBus: 0, bufferSize: 0, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            bufferCount += 1
            if bufferCount == 1 || bufferCount == 10 {
                print("[Shhhcribble] AudioRecorder buffer #\(bufferCount) frameLength=\(buffer.frameLength)")
            }

            // RMS for the audio level visualizer — read directly off the
            // tap-owned buffer; we don't need a copy for this.
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

            // Allocate a fresh buffer per callback sized to the actual
            // frameLength delivered. The tap reuses backing storage, so
            // yielding the original reference would let downstream consumers
            // observe mutated frames.
            if let copy = Self.copyBuffer(buffer) {
                self.onBuffer?(copy)
            }
        }
        try engine.start()
        isRunning = true
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        audioLog.notice("AVAudioEngineConfigurationChange — rebuilding engine")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Fresh engine — patching the existing one is unreliable when the
        // input device changed (AirPods reconnect, route swap).
        engine = AVAudioEngine()
        do {
            try installTapAndStart()
            audioLog.notice("Engine rebuilt OK after route change")
        } catch {
            audioLog.error("Engine rebuild failed: \(String(describing: error), privacy: .public)")
            isRunning = false
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
