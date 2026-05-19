import AVFoundation
import Foundation
import PushToTalk
import ShhhcribbleShared
import UIKit
import os

private let pttLog = Logger(subsystem: "com.shhhcribble.diag", category: "ptt")

/// Wraps Apple's `PTChannelManager` so the main app joins a single
/// Shhhcribble dictation channel at launch and stays joined across
/// backgrounding. Phase J Tier 2 (2026-05-19).
///
/// Why we use PTT for a dictation app:
/// - `UIBackgroundModes: push-to-talk` gives iOS the strongest hint to
///   keep our audio session resumable from background.
/// - PTT entitlement lets the keyboard wake the main app via local
///   IPC + then begin transmission, even when the app was suspended.
/// - The PT framework manages the recording indicator automatically.
///
/// Reverse-engineered from Superwhisper iOS — see SUPERWHISPER_RE.md.
@MainActor
final class PushToTalkService: NSObject {
    static let shared = PushToTalkService()

    private var manager: PTChannelManager?
    private var channelUUID: UUID?

    private static let channelUUIDKey = "ptt.channelUUID"

    /// Idempotent — safe to call multiple times. Joins the channel if
    /// not already joined. Call from `ShhhcribbleApp.init` (early) so
    /// iOS sees us as a PT app from launch.
    func start() {
        guard manager == nil else { return }
        // PT framework's class-method initialiser is a completion-handler
        // API that doesn't bridge cleanly to async/await in our Swift
        // version. Use the completion-handler form.
        PTChannelManager.channelManager(
            delegate: self,
            restorationDelegate: self
        ) { [weak self] manager, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    print("[Shhhcribble] PTT ERROR: PT init failed: \(String(describing: error))")
                    return
                }
                guard let manager else { return }
                self.manager = manager
                print("[Shhhcribble] PTT: PTChannelManager initialised")
                self.joinChannelIfNeeded()
            }
        }
    }

    private func joinChannelIfNeeded() {
        guard let manager else { return }
        let uuid = resolveOrCreateChannelUUID()
        self.channelUUID = uuid
        let descriptor = PTChannelDescriptor(
            name: "Shhhcribble Dictation",
            image: UIImage(systemName: "mic.fill")
        )
        manager.requestJoinChannel(channelUUID: uuid, descriptor: descriptor)
        print("[Shhhcribble] PTT: requestJoinChannel sent \(uuid)")
    }

    /// Begin transmission on the channel — flips iOS into "user is
    /// actively recording" mode. Triggers `didBeginTransmittingFrom`.
    func beginTransmission() {
        guard let manager, let channelUUID else {
            print("[Shhhcribble] PTT ERROR: beginTransmission: no manager/channel")
            return
        }
        manager.requestBeginTransmitting(channelUUID: channelUUID)
    }

    /// End transmission. Triggers `didEndTransmittingFrom`.
    func endTransmission() {
        guard let manager, let channelUUID else { return }
        manager.stopTransmitting(channelUUID: channelUUID)
    }

    // MARK: - Channel UUID persistence

    private func resolveOrCreateChannelUUID() -> UUID {
        let defaults = KeyboardBridge.defaults ?? UserDefaults.standard
        if let raw = defaults.string(forKey: Self.channelUUIDKey),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }
        let uuid = UUID()
        defaults.set(uuid.uuidString, forKey: Self.channelUUIDKey)
        return uuid
    }
}

// MARK: - PTChannelManagerDelegate

extension PushToTalkService: PTChannelManagerDelegate {
    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        didJoinChannel channelUUID: UUID,
        reason: PTChannelJoinReason
    ) {
        print("[Shhhcribble] PTT: didJoinChannel \(channelUUID) reason=\(reason.rawValue)")
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        didLeaveChannel channelUUID: UUID,
        reason: PTChannelLeaveReason
    ) {
        print("[Shhhcribble] PTT: didLeaveChannel reason=\(reason.rawValue)")
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        channelUUID: UUID,
        didBeginTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        print("[Shhhcribble] PTT: didBeginTransmitting source=\(source.rawValue)")
        Task { @MainActor in
            do {
                try await TranscriptionService.shared.recordAndTranscribe(trigger: .keyboard)
            } catch {
                print("[Shhhcribble] PTT ERROR: recordAndTranscribe failed: \(String(describing: error))")
            }
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        channelUUID: UUID,
        didEndTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        print("[Shhhcribble] PTT: didEndTransmitting source=\(source.rawValue)")
        Task { @MainActor in
            await TranscriptionService.shared.stopRecording()
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        receivedEphemeralPushToken pushToken: Data
    ) {
        print("[Shhhcribble] PTT: receivedEphemeralPushToken (\(pushToken.count) bytes) — unused")
    }

    /// REQUIRED. PT framework calls this synchronously when an APNs push
    /// arrives for our channel. We don't drive PT via APNs (we use App
    /// Group / local IPC), so return a synthetic active-participant
    /// result so the framework accepts the push and keeps the channel.
    nonisolated func incomingPushResult(
        channelManager: PTChannelManager,
        channelUUID: UUID,
        pushPayload: [String: Any]
    ) -> PTPushResult {
        print("[Shhhcribble] PTT: incomingPushResult (server-driven path unused)")
        let participant = PTParticipant(name: "Shhhcribble", image: nil)
        return .activeRemoteParticipant(participant)
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        didActivate audioSession: AVAudioSession
    ) {
        print("[Shhhcribble] PTT: PT didActivate audioSession")
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        didDeactivate audioSession: AVAudioSession
    ) {
        print("[Shhhcribble] PTT: PT didDeactivate audioSession")
    }
}

// MARK: - PTChannelRestorationDelegate

extension PushToTalkService: PTChannelRestorationDelegate {
    nonisolated func channelDescriptor(
        restoredChannelUUID channelUUID: UUID
    ) -> PTChannelDescriptor {
        PTChannelDescriptor(
            name: "Shhhcribble Dictation",
            image: UIImage(systemName: "mic.fill")
        )
    }
}
