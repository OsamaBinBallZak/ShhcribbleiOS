import AVFoundation
import UIKit
import os

private let log = Logger(subsystem: "com.shhhcribble.diag", category: "audio-session")

/// Owns the global `AVAudioSession` and a single long-lived `AVAudioEngine`.
///
/// The engine has two coexisting responsibilities:
///
/// 1. **Output path** (always on, in warm mode): an `AVAudioPlayerNode`
///    plays silence into the main mixer continuously. This is what
///    keeps `setActive(true)` from being silently revoked and what makes
///    iOS consider us "actively doing audio work" — the prerequisite for
///    `UIBackgroundModes: audio` to keep the process non-suspended.
///
/// 2. **Input path** (only when recording): an external caller installs
///    a tap on the engine's input node via `installInputTap(...)` and
///    receives mic buffers. `removeInputTap()` pulls it back. The engine
///    keeps running between recordings — no engine teardown, no engine
///    rebuild per recording (unlike Hendri's previous design).
///
/// Trade-off accepted: a permanent orange microphone indicator in the
/// status bar. This is Apple's no-suppress-allowed privacy disclosure
/// for any app holding `.playAndRecord` + `setActive(true)`. SuperWhisper
/// makes the same trade-off.
///
/// Hendri's original AirPods rule was "rebuild engine on
/// `AVAudioEngineConfigurationChange`". We still observe that here
/// (rebuilding the warm engine instead of AudioRecorder's now), so
/// route changes self-heal.
final class AudioSessionManager: @unchecked Sendable {
    static let shared = AudioSessionManager()
    private init() {}

    private let session = AVAudioSession.sharedInstance()
    private(set) var warmEngine: AVAudioEngine?
    private var silentPlayer: AVAudioPlayerNode?
    private var silentBuffer: AVAudioPCMBuffer?
    private(set) var warmModeActive = false
    private var routeChangeObserver: NSObjectProtocol?
    private var inputTapInstalled = false

    // MARK: - Session lifecycle

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

    /// Activates the session and starts the silent-player engine. After
    /// this returns, the app stays alive in background until something
    /// tears the warm engine down. Call from main thread (typically
    /// `ShhhcribbleApp.init`).
    func enterWarmMode() {
        guard !warmModeActive else { return }
        activateRetrying()
        startEngine()
        observeRouteChanges()
        warmModeActive = true
        print("[Shhhcribble] entered warm mode (single engine, silent player)")
    }

    func exitWarmMode() {
        guard warmModeActive else { return }
        unobserveRouteChanges()
        stopEngine()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        warmModeActive = false
        print("[Shhhcribble] exited warm mode")
    }

    /// Re-enters warm mode after an interruption (phone call, Siri).
    func reactivateAfterInterruption() {
        guard warmModeActive else { return }
        stopEngine()
        activateRetrying()
        startEngine()
    }

    // MARK: - Recording API (called by AudioRecorder)

    /// Install a tap on the warm engine's input node. The engine must
    /// be running in warm mode for this to work. Returns true on success.
    func installInputTap(
        bufferSize: AVAudioFrameCount = 0,
        onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) -> Bool {
        guard let engine = warmEngine, engine.isRunning else {
            print("[Shhhcribble] installInputTap FAILED: warm engine not running")
            return false
        }
        if inputTapInstalled {
            print("[Shhhcribble] installInputTap: tap already installed, removing first")
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        print("[Shhhcribble] installInputTap: format sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            print("[Shhhcribble] installInputTap FAILED: input format invalid")
            return false
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: onBuffer)
        inputTapInstalled = true
        return true
    }

    func removeInputTap() {
        guard let engine = warmEngine, inputTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    // MARK: - Legacy API kept for compatibility

    func activate() {
        // No-op in warm mode — session is already active.
        if warmModeActive { return }
        activateRetrying()
    }

    func deactivate() {
        // No-op in warm mode — leaving session active is the whole point.
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

    private func startEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = engine.outputNode.inputFormat(forBus: 0)

        let frameCount = AVAudioFrameCount(format.sampleRate * 0.2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            print("[Shhhcribble] startEngine FAILED: could not allocate silent buffer")
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

    private func stopEngine() {
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

    private func handleRouteChange() {
        print("[Shhhcribble] AVAudioEngineConfigurationChange — rebuilding warm engine")
        // Preserve whether a tap was installed so AudioRecorder can be
        // notified to reinstall after rebuild. For now we just tear the
        // tap; AudioRecorder's reinstall is handled by its own observer
        // (the same notification fires).
        stopEngine()
        activateRetrying()
        startEngine()
    }
}
