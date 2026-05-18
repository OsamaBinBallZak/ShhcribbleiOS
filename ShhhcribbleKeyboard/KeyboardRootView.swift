import ShhhcribbleShared
import SwiftUI

/// Shared state between `KeyboardViewController` and the toolbar.
final class KeyboardState: ObservableObject {
    @Published var engineWarm: Bool = KeyboardBridge.isEngineWarm
    @Published var isTranscribing: Bool = false
    @Published var isRecordingActive: Bool = KeyboardBridge.isRecordingActive

    func refresh() {
        engineWarm = KeyboardBridge.isEngineWarm
        isRecordingActive = KeyboardBridge.isRecordingActive
    }
}

// MARK: - Toolbar (status + Voice button)
//
// Rendered ABOVE KeyboardKit's KeyboardView via the host
// KeyboardViewController's `setupKeyboardView { _ in VStack { Toolbar; KeyboardView } }`.
// The QWERTY surface itself is KeyboardKit (Phase I, 2026-05-18); we own only
// this toolbar plus the mic + transcription wiring back through App Group.

struct ShhhcribbleToolbar: View {
    @ObservedObject var state: KeyboardState
    let onVoice: () -> Void
    let onStopActive: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusLabel
            Spacer()
            voiceButton
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
    }

    private var statusLabel: some View {
        Group {
            if state.isTranscribing {
                Label("Transcribing…", systemImage: "waveform")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.secondary)
            } else if state.isRecordingActive {
                Label("Recording", systemImage: "record.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.red)
            } else if state.engineWarm {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("Shhhcribble")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private var voiceButton: some View {
        ZStack {
            Circle()
                .fill(buttonColor)
                .frame(width: 40, height: 40)
            if state.isTranscribing && !state.isRecordingActive {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: buttonSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            KeyboardBridge.debug("voiceButton.onTapGesture fired")
            onTap()
        }
    }

    private func onTap() {
        if state.isRecordingActive { onStopActive() } else { onVoice() }
    }

    private var buttonColor: Color {
        if state.isRecordingActive { return .red }
        if state.engineWarm { return .accentColor }
        return Color(.systemGray2)
    }

    private var buttonSymbol: String {
        if state.isRecordingActive { return "stop.fill" }
        return "mic.fill"
    }
}
