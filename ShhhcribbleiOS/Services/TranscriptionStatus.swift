import Foundation
import SwiftUI

/// `TranscriptionStatus` is the app-wide SwiftUI `@Observable` view-model
/// for the recording subsystem. It is the canonical UI contract — every
/// view that needs to render recording state binds to `.shared` rather
/// than to the underlying actors.
///
/// Both `TextEngine` (model + partial transcript) and `RecordingCoordinator`
/// (phase + append target + URL-launch flags) write to this object. It is
/// deliberately a kitchen sink: splitting it would ripple through every
/// view file for no locality win. If a future feature creates a real
/// locality problem, revisit then.
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
    /// True when the audio engine is running but no buffers have arrived
    /// for the staleness threshold (~1.5 s). Most common cause: AirPods
    /// held by another device (Mac via Continuity), or the user pulled
    /// the AirPods just as recording started. Set by AudioInput's
    /// watchdog timer; the recording overlay reads this and renders a
    /// "Waiting for audio device…" banner so the user understands why
    /// the waveform isn't moving.
    @Published var audioDeviceUnavailable: Bool = false

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

    /// Set the phase. Logs a warning if the transition isn't in the
    /// documented graph; the new phase is still applied either way so
    /// the UI never gets stuck.
    func setPhase(_ newPhase: RecordingPhase) {
        let prev = phase
        if !prev.canTransition(to: newPhase) {
            print("[Shhhcribble] ILLEGAL phase transition: \(prev) -> \(newPhase)")
        }
        phase = newPhase
    }
}
