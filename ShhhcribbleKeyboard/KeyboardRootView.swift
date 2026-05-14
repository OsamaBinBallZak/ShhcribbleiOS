import ShhhcribbleShared
import SwiftUI

/// Shared state between `KeyboardViewController` and the SwiftUI surface.
/// The controller updates these properties from outside the view tree;
/// `@Published` triggers a re-render.
final class KeyboardState: ObservableObject {
    @Published var engineWarm: Bool = KeyboardBridge.isEngineWarm
    @Published var isTranscribing: Bool = false

    func refresh() {
        engineWarm = KeyboardBridge.isEngineWarm
    }
}

/// Minimal keyboard surface. Two modes:
///
/// 1. **Warm** — main app's audio engine is alive in background. The mic
///    button accepts push-to-talk: hold to record, release to stop +
///    insert. No app switch needed.
///
/// 2. **Cold** — engine isn't running (first use, force-quit, reboot).
///    Show a "Tap to open Shhhcribble" banner that bootstraps via
///    `extensionContext.open`. After the user records once in the main
///    app and switches back, the engine stays warm.
struct KeyboardRootView: View {
    @ObservedObject var state: KeyboardState
    let onPushToTalkBegin: () -> Void
    let onPushToTalkEnd: () -> Void
    let onColdStart: () -> Void
    let onNextKeyboard: () -> Void

    @State private var isHolding = false
    @State private var showHoldHint = false
    @State private var pendingBegin: DispatchWorkItem?

    /// Minimum hold duration before push-to-talk fires. Below this, the gesture
    /// is treated as a stray tap and *no* signals are posted — avoids the
    /// race where start/stop arrive at the main app within the same actor
    /// frame.
    private let holdThreshold: TimeInterval = 0.2

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            if state.engineWarm {
                warmLayout
            } else {
                coldStartLayout
            }
        }
        .frame(height: 260)
    }

    // MARK: - Warm

    private var warmLayout: some View {
        HStack(spacing: 24) {
            Button(action: onNextKeyboard) {
                Image(systemName: "globe")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel("Switch keyboard")

            Spacer()

            micButton

            Spacer()

            // Spacer to balance the layout — mirrors the globe button.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
    }

    private var micButton: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isHolding ? Color.red : Color.accentColor)
                    .frame(width: 88, height: 88)
                    .scaleEffect(isHolding ? 1.08 : 1.0)
                    .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isHolding)

                if state.isTranscribing && !isHolding {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: isHolding ? "waveform" : "mic.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        // Schedule the "actually begin" callback to fire after
                        // the hold threshold. Cancelled if the user lifts before.
                        guard pendingBegin == nil, !isHolding, !state.isTranscribing else { return }
                        let work = DispatchWorkItem { [self] in
                            isHolding = true
                            pendingBegin = nil
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onPushToTalkBegin()
                        }
                        pendingBegin = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
                    }
                    .onEnded { _ in
                        if let pending = pendingBegin {
                            // Released before threshold — cancel pending begin,
                            // don't send any signals. Show a transient hint.
                            pending.cancel()
                            pendingBegin = nil
                            withAnimation(.easeOut(duration: 0.15)) { showHoldHint = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                withAnimation { showHoldHint = false }
                            }
                            return
                        }
                        guard isHolding else { return }
                        isHolding = false
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onPushToTalkEnd()
                    }
            )
            .accessibilityLabel("Hold to record")
            .accessibilityHint("Speak while holding. Release to insert the transcription.")

            Text(showHoldHint ? "Hold to record" : (isHolding ? "Listening…" : " "))
                .font(.caption2)
                .foregroundStyle(showHoldHint ? Color.orange : Color.secondary)
                .opacity(showHoldHint || isHolding ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: showHoldHint)
                .animation(.easeInOut(duration: 0.2), value: isHolding)
        }
    }

    // MARK: - Cold

    private var coldStartLayout: some View {
        VStack(spacing: 16) {
            HStack {
                Button(action: onNextKeyboard) {
                    Image(systemName: "globe")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Color.primary)
                        .frame(width: 44, height: 44)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .accessibilityLabel("Switch keyboard")
                Spacer()
            }
            .padding(.horizontal, 16)

            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(Color.accentColor)

                Text("Open Shhhcribble to start")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)

                Text("After your first recording, hold the mic here to dictate directly.")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button(action: onColdStart) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.app")
                        Text("Open Shhhcribble")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                }
                .padding(.top, 4)
            }

            Spacer()
        }
    }
}
