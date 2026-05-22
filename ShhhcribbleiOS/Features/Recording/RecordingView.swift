import SwiftUI
import UIKit

struct RecordingOverlayView: View {
    @ObservedObject var status: TranscriptionStatus
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        if status.overlayVisible {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                phaseContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch status.phase {
        case .recording:
            // Keyboard cold-start gets a dedicated takeover view, but only
            // until the first partial transcript arrives. Once we have text,
            // collapse to the normal recording overlay so the user can read
            // what they're saying.
            if status.launchedFromKeyboard && status.partialSnippet.isEmpty {
                ColdStartTakeover(
                    audioLevel: status.audioLevel,
                    onCancel: cancel
                )
                .onAppear { startTimer() }
                .onDisappear { stopTimer() }
            } else {
                recordingContent
                    .onAppear { startTimer() }
                    .onDisappear { stopTimer() }
            }
        case .error(let err):
            ErrorCard(error: err)
        case .idle:
            EmptyView()
        }
    }

    private var recordingContent: some View {
        VStack(spacing: 20) {
            if status.launchedViaURL {
                SwipeBackHint()
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
            }

            if let title = status.appendTargetTitle {
                AppendingToChip(title: title)
                    .padding(.horizontal, 24)
                    .padding(.top, status.launchedViaURL ? 0 : 24)
            }

            Text(timeString)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, (status.appendTargetTitle == nil && !status.launchedViaURL) ? 24 : 0)

            SoundwaveBars(audioLevel: status.audioLevel)
                .frame(width: 200, height: 72)

            if status.audioDeviceUnavailable {
                AudioDeviceUnavailableBanner()
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ScrollingLiveText(text: status.partialSnippet)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)

            HStack(spacing: 16) {
                Button(action: cancel) {
                    Text("Cancel")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                        )
                }

                Button(action: stop) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.doc.fill")
                        Text("Copy & Save")
                    }
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.accentColor)
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private var timeString: String {
        let total = Int(elapsed)
        return String(format: "%01d:%02d", total / 60, total % 60)
    }

    private func startTimer() {
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            elapsed += 0.1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func stop() {
        Task { await RecordingCoordinator.shared.stopRecording() }
    }

    private func cancel() {
        Task { await RecordingCoordinator.shared.cancelRecording() }
    }
}

// MARK: - Appending-to chip
//
// Display-only context indicator shown at the top of the recording overlay
// when the recording was launched from NoteDetailView's "Continue recording"
// button. Reassures the user the transcript will be appended rather than
// create a fresh note. Tappable-to-abandon was deliberately not added — the
// existing Cancel button already abandons the append cleanly.
private struct AppendingToChip: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.append")
                .font(.system(size: 12, weight: .semibold))
            Text("Adding to: \(title)")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color(.tertiarySystemFill))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Adding to note: \(title)")
    }
}

/// Shown at the top of the recording overlay when the recording was
/// launched via URL scheme from the keyboard extension (i.e.
/// `TranscriptionStatus.launchedViaURL == true`). Mirrors what Wispr
/// Flow / Aqua Voice surface after their iOS-26.4-imposed manual
/// swipe-back UX: tells the user how to get back to their previous app
/// while recording continues in the background.
private struct SwipeBackHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Swipe right on the bottom bar to return — recording continues")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Swipe right on the bottom bar to return to your previous app. Recording continues in the background.")
    }
}

/// Full-screen cold-start landing page for keyboard-triggered recordings.
/// Shown when `launchedFromKeyboard == true && phase == .recording &&
/// partialSnippet.isEmpty` — i.e. the user just tapped the keyboard mic,
/// the app foregrounded, but no transcript has arrived yet. As soon as
/// the first partial lands, the overlay collapses to the normal
/// `recordingContent` so the live text is visible.
///
/// Inspired by Superwhisper iOS's cold-start screen (per
/// SUPERWHISPER_RE.md). Replaces the small `SwipeBackHint` rectangle for
/// the keyboard case specifically; non-keyboard URL launches
/// (Back-Tap / Shortcut → `.manual`) still render `SwipeBackHint` inside
/// `recordingContent` because they have different "back-pill commits"
/// semantics.
private struct ColdStartTakeover: View {
    let audioLevel: Double
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Phone illustration with an orange "on air" dot near the
            // bottom-bar area. The dot's position approximates where iOS
            // renders the system home-indicator pill, so the visual reads
            // "swipe from there to return".
            ZStack(alignment: .bottom) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 104, weight: .light))
                    .foregroundStyle(.secondary)
                Image(systemName: "circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.bottom, 14)
            }

            VStack(spacing: 12) {
                Text("Shhhcribble is on")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text("Swipe right on the bottom bar to return to the keyboard.\nYour transcript will land where you were typing.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Small waveform so the user has confirmation the mic is live.
            SoundwaveBars(audioLevel: audioLevel)
                .frame(width: 140, height: 36)

            // "Install the shortcut to skip this screen next time" CTA.
            // Hidden until the bundled Shhhcribble.shortcut lands (Step 2
            // of the post-cleanup plan). The Bundle lookup returns nil
            // until then, so the row collapses without leaving an empty
            // affordance.
            if let installURL = Self.installShortcutURL() {
                Button {
                    UIApplication.shared.open(installURL)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Install dictation shortcut to skip this screen")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color(.tertiarySystemFill))
                    )
                }
            }

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shhhcribble is recording. Swipe right on the bottom bar to return to the keyboard. Your transcript will land where you were typing.")
    }

    /// Returns the iOS Shortcuts.app install URL for the bundled
    /// `Shhhcribble.shortcut` file, or nil if the file isn't bundled yet.
    /// The .shortcut ships via Step 2 of the post-cleanup plan; until
    /// then, this returns nil and the install CTA is hidden.
    ///
    /// Shared shape with the onboarding install button — if you change
    /// the URL format or filename here, mirror it in
    /// `OnboardingView.KeyboardPage`.
    static func installShortcutURL() -> URL? {
        guard let fileURL = Bundle.main.url(
            forResource: "Shhhcribble",
            withExtension: "shortcut"
        ) else {
            return nil
        }
        return URL(string: "shortcuts://import-shortcut?url=\(fileURL.absoluteString)&name=Toggle%20Shhhcribble%20Recording")
    }
}

/// Shown in the recording overlay when the audio engine is running
/// but no buffers have arrived for ~1.5 s. Most common cause: AirPods
/// are connected to another nearby device (often the user's Mac via
/// Continuity audio) and haven't released the input to the phone yet.
/// Auto-clears as soon as buffers start flowing.
private struct AudioDeviceUnavailableBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for audio device…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("AirPods or other Bluetooth headset may be in use by another device.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for audio device. AirPods or other Bluetooth headset may be in use by another device.")
    }
}

// MARK: - Error card
//
// Visible message + recovery action for the three error cases. Stays until
// the user taps a button — never auto-dismisses.
private struct ErrorCard: View {
    let error: RecordingError

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(iconColor)

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(error.message)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
                primaryActionButton

                Button(action: dismiss) {
                    Text("Dismiss")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                        )
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch error {
        case .micPermissionDenied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                dismiss()
            } label: {
                Text("Open Settings")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.accentColor)
                    )
            }
        case .modelLoadFailed, .other:
            RetryButton(onComplete: dismiss)
        }
    }

    private var icon: String {
        switch error {
        case .micPermissionDenied: return "mic.slash.fill"
        case .modelLoadFailed:     return "exclamationmark.triangle.fill"
        case .other:               return "exclamationmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch error {
        case .micPermissionDenied: return .orange
        case .modelLoadFailed, .other: return .red
        }
    }

    private var title: String {
        switch error {
        case .micPermissionDenied: return "Microphone access needed"
        case .modelLoadFailed:     return "Model couldn't load"
        case .other:               return "Something went wrong"
        }
    }

    private func dismiss() {
        TranscriptionStatus.shared.partialSnippet = ""
        TranscriptionStatus.shared.launchedViaURL = false
        TranscriptionStatus.shared.launchedFromKeyboard = false
        TranscriptionStatus.shared.setPhase(.idle)
    }
}

// Retry button with its own reload state so the spinner doesn't depend on
// parent re-renders. ~3-5 s on cold model load — without feedback the user
// double-taps.
private struct RetryButton: View {
    let onComplete: () -> Void
    @State private var reloading = false

    var body: some View {
        Button {
            reloading = true
            Task {
                await RecordingCoordinator.shared.reloadModel()
                await MainActor.run {
                    reloading = false
                    onComplete()
                }
            }
        } label: {
            Group {
                if reloading {
                    ProgressView().tint(.white)
                } else {
                    Text("Retry")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.accentColor)
            )
        }
        .disabled(reloading)
    }
}

// MARK: - Soundwave bars
//
// Scrolling history visualizer. Each tick we shift the level history left
// and append the current `audioLevel`, so the bars actually look like a
// waveform travelling across the strip (right edge = now, left edge = ~0.6 s
// ago). Much more "alive" than a static sin-wave pattern; the user sees the
// shape of their voice over time.
struct SoundwaveBars: View {
    let audioLevel: Double

    private let barCount = 11

    @State private var history: [Double] = Array(repeating: 0, count: 11)

    private let tick = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<barCount, id: \.self) { i in
                    let level = history[i]
                    // Shape the response: square-root makes quiet sounds
                    // more visible without the loud peaks pinning at max.
                    let shaped = level.squareRoot()
                    // Bars span 4 pt (silent) → ~95% of frame height (loud).
                    let h = max(4, shaped * Double(geo.size.height) * 0.95)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: h)
                        .animation(.easeOut(duration: 0.08), value: history[i])
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onReceive(tick) { _ in
            // Shift history left, append latest level on the right.
            history.removeFirst()
            history.append(audioLevel)
        }
    }
}

// MARK: - Scrolling live text
//
// Multi-line block that types characters one-at-a-time (~70 ms/char) and
// flows top-to-bottom across the available space. The text always appears
// near the bottom of the container (typing-from-bottom feel); when content
// exceeds the visible height, the ScrollView auto-scrolls so the latest
// character stays pinned to the bottom and older lines fade up through the
// top gradient mask.
struct ScrollingLiveText: View {
    let text: String

    @StateObject private var typer = TypingViewModel()

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(styledTranscript(typer.displayedText))
                        .font(.system(size: 24, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.vertical, 4)
                        .id("end")
                }
                .disabled(true)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .onChange(of: typer.displayedText) { _, _ in
                    // Light scroll animation: a short ease-out so multi-line
                    // wraps slide instead of jumping. Short enough that
                    // overlapping per-character animations still converge to
                    // the same end position smoothly.
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
            }
        }
        .mask(
            // Top fade only kicks in once the transcript has grown past
            // roughly two wrapped lines, so the very first words don't
            // render half-faded. The mask interpolates from "fully opaque"
            // (no effect) to the soft gradient as the displayed text length
            // approaches the threshold, with an animated transition.
            // Black here is the alpha channel for `.mask(_:)`, NOT a visible
            // colour — fully opaque black = visible, transparent = hidden.
            // Don't "system-colour" these stops.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(1.0 - maskOpacity),                location: 0.00),
                    .init(color: .black.opacity(1.0 - 0.85 * maskOpacity),         location: 0.08),
                    .init(color: .black.opacity(1.0 - 0.45 * maskOpacity),         location: 0.16),
                    .init(color: .black.opacity(1.0 - 0.15 * maskOpacity),         location: 0.24),
                    .init(color: .black,                                            location: 0.32),
                    .init(color: .black,                                            location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .animation(.easeOut(duration: 0.45), value: maskOpacity)
        )
        .onChange(of: text) { _, newValue in
            typer.updateTarget(newValue)
        }
        .onAppear {
            // Hard reset so leftover text from a prior recording can't ghost in.
            typer.reset()
            if !text.isEmpty { typer.updateTarget(text) }
        }
        .onDisappear { typer.reset() }
    }

    /// Mask opacity ramps from 0 (no top fade — first words appear fully
    /// bright) up to 1 (full gradient mask) as the transcript grows. Uses
    /// character count as a proxy for wrapped-line count: ~30 chars per
    /// line on iPhone at 24 pt, so the fade starts around line 3 and is
    /// fully applied by line ~5.
    private var maskOpacity: Double {
        let chars = typer.displayedText.count
        let onset: Double = 80
        let full: Double = 160
        if Double(chars) <= onset { return 0 }
        if Double(chars) >= full { return 1 }
        return (Double(chars) - onset) / (full - onset)
    }

    /// Build an AttributedString that fades older words to a dimmer
    /// foreground while the latest two words stay bright — gives the
    /// "color follows the typing" feel without per-character animation.
    private func styledTranscript(_ raw: String) -> AttributedString {
        guard !raw.isEmpty else { return AttributedString(" ") }

        var attr = AttributedString(raw)
        // Default colour for everything (older content).
        attr.foregroundColor = Color.primary.opacity(0.32)

        // Find word ranges by walking backwards from the end. We treat
        // any whitespace as a word boundary; `raw` may end mid-word so
        // we always include the trailing partial word as the freshest tier.
        let nsRaw = raw as NSString
        let length = nsRaw.length
        var rangesFromEnd: [NSRange] = []

        var idx = length
        while idx > 0 {
            // Walk back over whitespace.
            while idx > 0,
                  let scalar = Unicode.Scalar(nsRaw.character(at: idx - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                idx -= 1
            }
            let wordEnd = idx
            // Walk back over non-whitespace = the word body.
            while idx > 0,
                  let scalar = Unicode.Scalar(nsRaw.character(at: idx - 1)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                idx -= 1
            }
            let wordStart = idx
            if wordEnd > wordStart {
                rangesFromEnd.append(NSRange(location: wordStart, length: wordEnd - wordStart))
            }
            if rangesFromEnd.count >= 5 { break }
        }

        // Tiered opacity from the trailing edge backward.
        let tiers: [Double] = [0.95, 0.95, 0.72, 0.55, 0.42]
        for (i, nsRange) in rangesFromEnd.enumerated() {
            guard let range = Range(nsRange, in: raw),
                  let attrRange = Range(range, in: attr) else { continue }
            attr[attrRange].foregroundColor = Color.primary.opacity(tiers[i])
        }
        return attr
    }
}

@MainActor
final class TypingViewModel: ObservableObject {
    @Published var displayedText: String = ""
    private var targetText: String = ""
    private var typingTask: Task<Void, Never>?
    /// Counts consecutive `updateTarget` calls that we rejected (i.e.
    /// the new text was a content revision too large to honour). After
    /// `rejectionLimit` rejections we force-accept the next update to
    /// avoid the display freezing indefinitely when TDT is making lots
    /// of small word changes none of which extend `displayedText`.
    private var rejectedInARow: Int = 0
    /// Maximum rewind distance (characters) we allow without forcing
    /// the rejection path. Tuned to catch single-word corrections like
    /// "their" → "there" (small) while blocking catastrophic flips
    /// like "Hello world this is a test" → "Goodbye" (large rewind).
    private static let maxAllowedRewind = 15
    /// After this many consecutive rejections, force-accept the next
    /// update. At ~700 ms per TDT live iteration, 4 rejections ≈ 2.8 s
    /// of staleness — about the longest we'd want to leave the user
    /// staring at a frozen display.
    private static let rejectionLimit = 4

    func updateTarget(_ newText: String) {
        // Four cases in order:
        //
        // 1. Strict prefix match → standard forward append (no flicker).
        //
        // 2. Normalised prefix match (same content, different format) →
        //    snap in place to update casing/punctuation without rewind.
        //
        // 3. Small content revision (rewind ≤ maxAllowedRewind chars) →
        //    honour the rewind. Catches "their" → "there" type fixes
        //    fluidly; user perceives a small in-place correction.
        //
        // 4. Large content revision → REJECT, keep current displayed.
        //    These are the catastrophic flips that flicker badly. After
        //    `rejectionLimit` consecutive rejections, force-accept the
        //    next one to avoid permanent freeze.
        //
        // See backlog.md "Live-preview text stability strategy revisit"
        // for future improvements (word-level confidence freeze, etc).
        if newText.hasPrefix(displayedText) {
            targetText = newText
            rejectedInARow = 0
        } else if Self.normalise(newText).hasPrefix(Self.normalise(displayedText)) {
            // Pure formatting revision. Snap displayed to the new text's
            // first `displayedText.count` characters; from here the typer
            // appends the rest as usual.
            let snapLen = min(displayedText.count, newText.count)
            displayedText = String(newText.prefix(snapLen))
            targetText = newText
            rejectedInARow = 0
        } else {
            // Genuine content revision. Compute the rewind distance.
            var commonLen = 0
            let dChars = Array(displayedText)
            let nChars = Array(newText)
            for i in 0..<min(dChars.count, nChars.count) {
                if dChars[i] == nChars[i] { commonLen = i + 1 } else { break }
            }
            let rewindDistance = displayedText.count - commonLen
            let underThreshold = rewindDistance <= Self.maxAllowedRewind
            let forceAccept = rejectedInARow >= Self.rejectionLimit
            if underThreshold || forceAccept {
                displayedText = String(displayedText.prefix(commonLen))
                targetText = newText
                rejectedInARow = 0
            } else {
                // Reject — keep current displayed, don't restart typer.
                rejectedInARow += 1
                return
            }
        }

        typingTask?.cancel()
        typingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current = self.displayedText
                let target = self.targetText
                let gap = target.count - current.count
                guard gap > 0 else { break }
                let nextIdx = target.index(target.startIndex, offsetBy: current.count)
                self.displayedText = String(target[target.startIndex...nextIdx])

                // Adaptive cadence — speed up when far behind so we don't
                // trail real speech. Slow to a natural reading rhythm when
                // the typer is close to caught up.
                let intervalMs: Int = gap > 80 ? 12
                                     : gap > 30 ? 28
                                     : gap > 10 ? 50
                                                : 70
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    func reset() {
        typingTask?.cancel()
        typingTask = nil
        displayedText = ""
        targetText = ""
        rejectedInARow = 0
    }

    /// Strip punctuation and lowercase. Used by `updateTarget` to detect
    /// when a TDT re-transcribe revised only the formatting of the text,
    /// not the actual words. The two strings are byte-different but
    /// content-equivalent, so we adopt the new one in place without the
    /// rewind animation that would otherwise flicker.
    private static func normalise(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }.reduce(into: "") { $0.append(Character($1)) }
    }
}
