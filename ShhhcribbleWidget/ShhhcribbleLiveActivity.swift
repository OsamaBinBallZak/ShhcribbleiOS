import ActivityKit
import AppIntents
import ShhhcribbleShared
import SwiftUI
import WidgetKit

private let brandBlue = Color(red: 0.25, green: 0.55, blue: 1.0)
private let pillBackground = Color(red: 0.10, green: 0.10, blue: 0.12)

struct ShhhcribbleLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShhhcribbleActivityAttributes.self) { context in
            // Lock-screen / banner layout. Per-button intents route into the
            // main app via App Group (restored 2026-05-14).
            HStack(spacing: 12) {
                AnimatedWaveform(size: 22)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture,
                         pauseTime: nil, countsDown: false)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()

                    Text(context.state.snippet.isEmpty ? "Listening…" : context.state.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.15), value: context.state.snippet)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(intent: StopRecordingIntent()) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(brandBlue))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .activityBackgroundTint(pillBackground)
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        AnimatedWaveform(size: 16)
                        Text("Recording")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: StopRecordingIntent()) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(brandBlue))
                    }
                    .buttonStyle(.plain)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture,
                         pauseTime: nil, countsDown: false)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.snippet.isEmpty ? "Listening…" : context.state.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.15), value: context.state.snippet)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                AnimatedWaveform(size: 14)
            } compactTrailing: {
                Circle()
                    .fill(brandBlue)
                    .frame(width: 8, height: 8)
            } minimal: {
                AnimatedWaveform(size: 14)
            }
            .keylineTint(brandBlue)
        }
    }
}

// MARK: - Animated waveform
//
// Self-animating waveform built from primitive shapes so we don't depend
// on `.symbolEffect` working in this widget context. Uses TimelineView
// `.animation` schedule which IS supported in widgets — SwiftUI redraws on
// each timeline date and we drive bar heights from a sin wave at that
// instant. Result: visible continuous motion without state updates.
private struct AnimatedWaveform: View {
    let size: CGFloat
    private let barCount = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: max(1, size * 0.08)) {
                ForEach(0..<barCount, id: \.self) { i in
                    let phase = t * 4 + Double(i) * 0.6
                    let normalized = 0.45 + 0.55 * (sin(phase) * 0.5 + 0.5)
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: max(1.5, size * 0.12),
                               height: size * CGFloat(normalized))
                }
            }
            .frame(width: size * 1.4, height: size, alignment: .center)
        }
    }
}
