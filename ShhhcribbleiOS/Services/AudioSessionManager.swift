import AVFoundation
import UIKit
import os

private let log = Logger(subsystem: "com.shhhcribble.diag", category: "audio-session")

/// Maintains the global `AVAudioSession` plus a "warm" engine running a
/// silent player node. The warm engine has two jobs:
///
/// 1. Keep `setActive(true)` from being silently revoked. iOS interrupts
///    apps that hold `.playAndRecord` active but don't actually produce
///    any audio — Apple's "stopping playback for too long" interrupt.
/// 2. Combined with `UIBackgroundModes: audio`, keep the app process
///    non-suspended in the background. This is the prerequisite for the
///    keyboard extension's push-to-talk to deliver Darwin notifications
///    (suspended apps don't receive them — confirmed by Apple DTS,
///    forum 769398).
///
/// The recording-capture engine (`AudioRecorder`) is still recreated per
/// recording because Hendri's CLAUDE.md note about AirPods route-change
/// self-healing still applies. We run two engines simultaneously: this
/// keepalive engine for output, AudioRecorder's engine for input. They
/// share the same `AVAudioSession`.
/// Not `@MainActor` so the existing `TranscriptionService` actor and
/// `AudioInterruptionObserver` call sites continue to work synchronously.
/// `AVAudioSession.sharedInstance()` methods are thread-safe; the warm
/// engine is touched only via `MainActor.run` blocks internally.
final class AudioSessionManager: @unchecked Sendable {
    static let shared = AudioSessionManager()
    private init() {}

    private let session = AVAudioSession.sharedInstance()
    private var warmEngine: AVAudioEngine?
    private var silentPlayer: AVAudioPlayerNode?
    private(set) var warmModeActive = false

    /// Configures the session category and prepares for warm mode. Call
    /// once at app launch.
    func configure() {
        do {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            // .playAndRecord lets the silent player produce output AND
            // future recordings capture input on the same session. The
            // .mixWithOthers option lets the user keep music playing
            // while we hold the session.
            // Restored to Hendri's original config — `.playAndRecord` with
            // a silent-player warm engine broke the input node format
            // (IsFormatSampleRateAndChannelCountValid crash in installTap).
            // For now, revert to the recording-only category and accept
            // that the app gets suspended after backgrounding. We'll add
            // a different keepalive strategy in a follow-up.
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            print("[Shhhcribble] session category set: .record/.measurement (no warm engine)")
        } catch {
            log.error("session configure failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Activates the session and starts the silent-player engine. After
    /// this returns, the app stays alive in background until something
    /// tears the warm engine down. Call from main thread (typically
    /// `ShhhcribbleApp.init`).
    func enterWarmMode() {
        guard !warmModeActive else { return }
        activateRetrying()
        startWarmEngine()
        warmModeActive = true
        log.notice("entered warm mode")
    }

    /// Stops the silent-player engine and deactivates the session. Used
    /// when the user disables the "keep keyboard ready" setting.
    func exitWarmMode() {
        guard warmModeActive else { return }
        stopWarmEngine()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        warmModeActive = false
        log.notice("exited warm mode")
    }

    /// Re-enters warm mode after an interruption (phone call, Siri).
    /// Called from `AudioInterruptionObserver`.
    func reactivateAfterInterruption() {
        guard warmModeActive else { return }
        stopWarmEngine()
        activateRetrying()
        startWarmEngine()
    }

    /// Pause the warm engine for the duration of a real recording. Two
    /// engines sharing the same `.playAndRecord` session corrupts the
    /// input node's format (empirically — crashes with
    /// `IsFormatSampleRateAndChannelCountValid` in `installTap`).
    /// Full teardown + session deactivate; the recording's own configure
    /// + activate will set the session back up cleanly.
    func pauseWarmEngine() {
        guard warmModeActive else { return }
        print("[Shhhcribble] pausing warm engine for active recording")
        stopWarmEngine()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Restart the warm engine after a recording finishes.
    func resumeWarmEngine() {
        guard warmModeActive, warmEngine == nil else { return }
        print("[Shhhcribble] resuming warm engine after recording")
        activateRetrying()
        startWarmEngine()
    }

    // MARK: - Legacy API used by AudioRecorder
    //
    // Existing callers (TranscriptionService, recordAndTranscribe path)
    // call activate() / deactivate() around their recordings. Keep those
    // working — they now no-op when warm mode is already active.

    func activate() {
        if warmModeActive { return }
        activateRetrying()
    }

    func deactivate() {
        // Don't deactivate if warm mode is on — that would tear down the
        // keyboard's wake path. Caller intends to deactivate after a
        // recording finishes; if we're permanently warm we ignore it.
        if warmModeActive { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Internals

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

    private func startWarmEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = engine.outputNode.inputFormat(forBus: 0)

        // 200 ms of silence. iOS just needs to see continuous output flow;
        // the buffer length doesn't matter as long as we keep scheduling
        // it. We loop-schedule it forever.
        let frameCount = AVAudioFrameCount(format.sampleRate * 0.2)
        guard let silentBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            log.error("could not allocate silent buffer for warm engine")
            return
        }
        silentBuffer.frameLength = frameCount
        // PCM buffers are zero-initialised on alloc — that's literal silence.

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Volume to zero just in case the format ever carries non-zero
        // data (e.g. after an interruption-resume the buffer survived).
        engine.mainMixerNode.outputVolume = 0.0

        do {
            try engine.start()
            player.play()
            scheduleSilentLoop(player: player, buffer: silentBuffer)
            self.warmEngine = engine
            self.silentPlayer = player
            log.notice("warm engine started (silent loop scheduled)")
        } catch {
            log.error("warm engine start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleSilentLoop(player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer) {
        // Re-schedule manually in the completion handler so each buffer
        // is independently tracked. Completion runs on an internal audio
        // thread; re-hop to main for the next schedule to keep engine
        // accesses single-threaded.
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self, weak player] in
            guard let player else { return }
            DispatchQueue.main.async {
                guard let self, self.warmEngine?.isRunning == true else { return }
                self.scheduleSilentLoop(player: player, buffer: buffer)
            }
        }
    }

    private func stopWarmEngine() {
        silentPlayer?.stop()
        warmEngine?.stop()
        silentPlayer = nil
        warmEngine = nil
    }
}
