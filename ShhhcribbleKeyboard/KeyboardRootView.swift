import ShhhcribbleShared
import SwiftUI

/// Shared state between `KeyboardViewController` and the toolbar.
/// Polls the App Group for live recording info (audio level + partial
/// transcript) while a recording is active, so the pill can render an
/// audio-bars waveform + scrolling live transcript matching the Mac
/// overlay's design language.
final class KeyboardState: ObservableObject {
    @Published var engineWarm: Bool = KeyboardBridge.isEngineWarm
    @Published var isTranscribing: Bool = false
    @Published var isRecordingActive: Bool = KeyboardBridge.isRecordingActive
    @Published var liveAudioLevel: Double = 0
    @Published var livePartial: String = ""

    func refresh() {
        engineWarm = KeyboardBridge.isEngineWarm
        let wasRecording = isRecordingActive
        isRecordingActive = KeyboardBridge.isRecordingActive

        if isRecordingActive {
            liveAudioLevel = KeyboardBridge.liveAudioLevel
            livePartial = KeyboardBridge.livePartial
        } else if wasRecording {
            // Recording just ended — wipe local state so the pill snaps
            // back to idle without a moment of stale waveform.
            liveAudioLevel = 0
            livePartial = ""
        }
    }
}

// MARK: - Pill toolbar (Sprint 8 redesign, 2026-05-21)
//
// Replaces the gray system-keyboard-style toolbar with a dark rounded
// pill matching the Shhhcribble Mac overlay. 38pt tall (down from 48).
//
// Renders into the host KeyboardViewController's
// `setupKeyboardView { _ in VStack { ShhhcribbleToolbar; KeyboardView } }`.
// The QWERTY surface remains KeyboardKit — we own only this pill plus
// the mic + transcription wiring back through App Group.

struct ShhhcribbleToolbar: View {
    @ObservedObject var state: KeyboardState
    let onVoice: () -> Void
    let onStopActive: () -> Void

    var body: some View {
        // 4pt padding all around the pill so the gray keyboard surface
        // "wraps" it with equal margins. Total toolbar height: 4 + 38 +
        // 4 = 46pt. The outer KeyboardViewController VStack should NOT
        // add additional vertical padding on top of this.
        ShhhcribblePill(
            state: state,
            onVoice: onVoice,
            onStopActive: onStopActive
        )
        .padding(4)
    }
}

/// The dark rounded pill itself. Layout left-to-right:
///   - mic icon (18pt, color-coded by state)
///   - audio bars (5 vertical bars, recording-only)
///   - status text or scrolling live transcript
///   - action button (mic 24pt blue / stop 28pt red / transcribing 28pt ghost)
///
/// Both action buttons sit so their center matches the pill's right
/// rounded-end center (concentric). Sizes differ by state but the
/// position lock keeps the visual anchor stable through transitions.
private struct ShhhcribblePill: View {
    @ObservedObject var state: KeyboardState
    let onVoice: () -> Void
    let onStopActive: () -> Void

    private static let pillHeight: CGFloat = 38

    var body: some View {
        HStack(spacing: 8) {
            // Waveform always visible — bars sit at baseline 3pt when
            // idle (since liveAudioLevel is 0), then animate to driven
            // heights when recording starts. Makes the transition into
            // recording feel like the bars "wake up" rather than
            // appearing from nowhere.
            audioBars
            statusText
                .frame(maxWidth: .infinity, alignment: .trailing)
            trailingAction
        }
        // No leading mic icon — the right-side action button already
        // carries a mic glyph when idle (and a stop square when
        // recording). Two mic icons on a 38pt pill was redundant.
        .padding(.leading, 16)
        .frame(height: Self.pillHeight)
        .background(
            RoundedRectangle(cornerRadius: Self.pillHeight / 2, style: .continuous)
                .fill(pillBackground)
        )
    }

    // MARK: Pieces

    private var audioBars: some View {
        // Five vertical bars, heights modulated by liveAudioLevel.
        // Each bar gets a slightly different scaling so the cluster
        // looks like a waveform rather than five identical sticks.
        //
        // Sensitivity: AudioInput already scales RMS by 12× to map
        // normal speech to ~1.0, but for the small keyboard pill that
        // signal looks too flat. Boost by another 1.8× (clamped to 1.0)
        // so even quieter speech drives visible movement.
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let factor: Double = [0.4, 0.85, 1.0, 0.6, 0.3][i]
                let amplified = min(1.0, state.liveAudioLevel * 2.5)
                let height = max(3, amplified * 22 * factor)
                Capsule()
                    .fill(state.isRecordingActive
                          ? Color.red
                          : Color.black.opacity(0.30))
                    .frame(width: 2, height: CGFloat(height))
                    .animation(.easeOut(duration: 0.08), value: state.liveAudioLevel)
                    .animation(.easeInOut(duration: 0.18), value: state.isRecordingActive)
            }
        }
        .frame(height: 22)
    }

    private var statusText: some View {
        // Right-aligned, fades on the LEFT so the trailing characters
        // (the most-recent ones) remain visible as the partial grows.
        Text(statusString)
            .font(.footnote.weight(.medium))
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .truncationMode(.head)
            .mask(
                // Fade-out happens only in the first ~10% of the
                // available width. Earlier we had a 33% fade ramp
                // which clipped short labels like "Ready" before they
                // were fully visible (Tiuri: 2026-05-22). With this
                // tighter ramp, short status text is fully legible and
                // only long scrolling transcripts get masked at the
                // leading edge.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0.0),
                        .init(color: .black,            location: 0.10),
                        .init(color: .black,            location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }

    @ViewBuilder
    private var trailingAction: some View {
        if state.isTranscribing {
            transcribingButton
        } else if state.isRecordingActive {
            stopButton
        } else {
            micButton
        }
    }

    // MARK: Action buttons — same center, different sizes

    private var micButton: some View {
        // 24pt blue circle, margin-right 7pt → center at -19 from pill
        // right edge (concentric w/ rounded end). Tap → onVoice().
        // Wrapped in Button + PressDownButtonStyle so tapping it
        // scale-dims briefly (no built-in feedback on a custom
        // shape; Tiuri couldn't tell if the tap had registered).
        Button {
            KeyboardBridge.debug("voiceButton fired (idle mic)")
            onVoice()
        } label: {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
        .buttonStyle(PressDownButtonStyle())
        .padding(.trailing, 7)
    }

    private var stopButton: some View {
        // 28pt red rounded-square. Margin-right 5pt → same center as
        // micButton. Tap → onStopActive().
        Button {
            KeyboardBridge.debug("voiceButton fired (stop)")
            onStopActive()
        } label: {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.red)
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.white)
                        .frame(width: 12, height: 12)
                )
        }
        .buttonStyle(PressDownButtonStyle())
        .padding(.trailing, 5)
    }

    private var transcribingButton: some View {
        // 28pt "ghost" stop while transcription is in flight. Spinner
        // overlay communicates progress. Same right-margin as stop so
        // the visual anchor stays put across the transition.
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.18))
            .frame(width: 28, height: 28)
            .overlay(
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white.opacity(0.6))
                    .scaleEffect(0.6)
            )
            .padding(.trailing, 5)
    }

    // MARK: Style helpers

    private var pillBackground: Color {
        // Light grey — close to the keyboard's own surface but just
        // a touch darker so the pill is still distinguishable. The
        // previous medium-grey read as "in your face" against the
        // light keyboard tone (Tiuri, 2026-05-22). Tracks roughly the
        // tone between system-gray and the keyboard background.
        if state.isRecordingActive {
            // Faint warm tint during recording. Subtle enough that
            // it's not jarring, perceptible enough to read as "in
            // recording mode" alongside the red stop button.
            return Color(red: 0.74, green: 0.69, blue: 0.71)
        }
        return Color(red: 0.72, green: 0.72, blue: 0.74)
    }

    private var statusColor: Color {
        // Dark text against the new light-grey pill background. Live
        // transcript gets full primary weight; placeholder/status copy
        // ("Tap to dictate" / "Ready" / "Listening…") gets a softer
        // secondary tone so it doesn't compete with the action button.
        if state.isRecordingActive && !state.livePartial.isEmpty {
            return Color.black.opacity(0.85)
        }
        return Color.black.opacity(0.55)
    }

    private var statusString: String {
        if state.isTranscribing { return "Transcribing…" }
        if state.isRecordingActive {
            return state.livePartial.isEmpty ? "Listening…" : state.livePartial
        }
        if state.engineWarm { return "Ready" }
        return "Tap to dictate"
    }
}

/// Tap feedback for the pill's action buttons. Standard SwiftUI
/// `Button` has no visible press state on custom shapes, so users
/// (Tiuri 2026-05-22) couldn't tell whether a tap had registered.
/// On press: scale to 0.85 + dim opacity slightly. Snappy 0.08s
/// animation in, ease-out on release.
private struct PressDownButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
