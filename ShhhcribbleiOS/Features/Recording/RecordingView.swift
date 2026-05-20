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
            recordingContent
                .onAppear { startTimer() }
                .onDisappear { stopTimer() }
        case .error(let err):
            ErrorCard(error: err)
        case .idle:
            EmptyView()
        }
    }

    private var recordingContent: some View {
        VStack(spacing: 20) {
            if let title = status.appendTargetTitle {
                AppendingToChip(title: title)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
            }

            Text(timeString)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, status.appendTargetTitle == nil ? 24 : 0)

            SoundwaveBars(audioLevel: status.audioLevel)
                .frame(width: 200, height: 72)

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
        Task { await TranscriptionService.shared.stopRecording() }
    }

    private func cancel() {
        Task { await TranscriptionService.shared.cancelRecording() }
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
                await TranscriptionService.shared.reloadModel()
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

    func updateTarget(_ newText: String) {
        // Three cases, in order of preference:
        //
        // 1. Strict prefix match — the new partial just appended to the end.
        //    Standard append-typing animation.
        //
        // 2. Normalised prefix match — the new text is a strict prefix of the
        //    displayed once we strip punctuation + casing. This is what TDT
        //    does on most iterations: it re-transcribes the full audio buffer
        //    every ~700 ms, and the model freely revises punctuation /
        //    capitalisation as more context arrives. The content didn't
        //    change, only the format. Adopt the new text *in place* up to
        //    the current displayed length and let the typer continue forward
        //    into the new tail. The reader sees a soft "Hello" → "Hello,"
        //    rather than a flicker-and-rewind.
        //
        //    Pre-streaming-removal (Phase J Tier 5), this normalised path
        //    wasn't needed because the StreamingEouAsrManager produced
        //    stable left-to-right partials within a chunk. TDT's re-
        //    transcribe-the-whole-thing approach revises freely, which
        //    triggered the legacy rewind logic on most iterations and
        //    showed up as visible flicker — see Item 1 in plan
        //    yes-the-plan-is-steady-spindle.md.
        //
        // 3. Genuine content revision — engine actually changed words. Keep
        //    the legacy rewind-to-common-prefix behaviour.
        if newText.hasPrefix(displayedText) {
            targetText = newText
        } else if Self.normalise(newText).hasPrefix(Self.normalise(displayedText)) {
            // Pure formatting revision. Snap displayed to the new text's
            // first `displayedText.count` characters; from here the typer
            // appends the rest as usual.
            let snapLen = min(displayedText.count, newText.count)
            displayedText = String(newText.prefix(snapLen))
            targetText = newText
        } else {
            // Content revised. Walk back to common prefix and resume.
            var commonLen = 0
            let dChars = Array(displayedText)
            let nChars = Array(newText)
            for i in 0..<min(dChars.count, nChars.count) {
                if dChars[i] == nChars[i] { commonLen = i + 1 } else { break }
            }
            displayedText = String(displayedText.prefix(commonLen))
            targetText = newText
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
