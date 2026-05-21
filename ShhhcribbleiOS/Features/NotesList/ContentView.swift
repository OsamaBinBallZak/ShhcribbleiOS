import SwiftUI

/// Tracks which note (if any) is currently presented in NoteDetailView. Used
/// by the floating action area to surface a "Continue recording" mini button
/// next to the play FAB while the user is reading a note.
@MainActor
final class NoteFocus: ObservableObject {
    static let shared = NoteFocus()
    @Published var activeNoteId: UUID?
    /// True when a sub-view (e.g. Feedback list) wants to hide the
    /// global play FAB so its own record button is the only one on
    /// screen. Set in `.onAppear`, cleared in `.onDisappear`.
    @Published var hideGlobalPlayFAB: Bool = false
    private init() {}
}

struct ContentView: View {
    enum BottomTab { case notes, settings }

    @StateObject private var status = TranscriptionStatus.shared
    @StateObject private var noteFocus = NoteFocus.shared
    @State private var tab: BottomTab = .notes

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .notes:    NotesListView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 0) {
                TabPill(tab: $tab)
                Spacer()
                if !status.isRecording && !noteFocus.hideGlobalPlayFAB {
                    HStack(spacing: 10) {
                        if let id = noteFocus.activeNoteId {
                            ContinueRecordingButton(
                                noteId: id,
                                isEnabled: status.model == .ready
                            )
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                        StartRecordingButton(
                            isEnabled: status.model == .ready,
                            downloadProgress: status.modelDownloadProgress
                        )
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.32, dampingFraction: 0.8),
                               value: noteFocus.activeNoteId)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: noteFocus.hideGlobalPlayFAB)
            // ↑ smooth-fade the entire trailing FAB group when sub-views
            // (like FeedbackListView) request the global FAB hidden.
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            .zIndex(2) // keep the tab bar + play button above any underlying scroll views

            ToastOverlay()
                .zIndex(3)
        }
    }
}

private struct TabPill: View {
    @Binding var tab: ContentView.BottomTab
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 0) {
            item(.notes, label: "Notes", icon: "note.text")
            item(.settings, label: "Settings", icon: "gearshape")
        }
        .padding(6)
        .modifier(GlassPillBackground())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private func item(_ value: ContentView.BottomTab, label: String, icon: String) -> some View {
        let selected = tab == value
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                tab = value
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Color(red: 0.25, green: 0.55, blue: 1.0) : .primary)
            .frame(width: 78, height: 52)
            .background {
                if selected {
                    Capsule()
                        .fill(.thinMaterial)
                        .matchedGeometryEffect(id: "tab.selection", in: pillNamespace)
                }
            }
            .contentShape(Rectangle()) // explicit hit area for the full 78×52 frame
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct GlassPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: Capsule())
        } else {
            content
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
        }
    }
}

// Smaller, tinted sibling of the play FAB. Visible only while a note is
// presented in NoteDetailView (`NoteFocus.shared.activeNoteId != nil`), so
// taps unambiguously append to that specific note rather than create a fresh
// one.
private struct ContinueRecordingButton: View {
    let noteId: UUID
    let isEnabled: Bool

    var body: some View {
        Button(action: start) {
            Image(systemName: "mic.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 1.0))
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(Color(red: 0.25, green: 0.55, blue: 1.0)
                                  .opacity(isEnabled ? 0.18 : 0.10))
                )
                .overlay(
                    Circle().strokeBorder(
                        Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.35),
                        lineWidth: 0.75
                    )
                )
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Continue recording on this note")
    }

    private func start() {
        Task {
            try? await RecordingCoordinator.shared.recordAndTranscribe(
                trigger: .manual,
                appendingTo: noteId
            )
        }
    }
}

private struct StartRecordingButton: View {
    let isEnabled: Bool
    /// Non-nil only while the first-ever model download is in progress.
    /// Drives the circular ring that wraps the play button.
    let downloadProgress: Double?

    var body: some View {
        Button(action: start) {
            // Harry's first-round feedback (backlog FB-3): a "play"
            // triangle reads as "play something that exists" — confusing
            // for a recording action. Mic icon is the unambiguous "start
            // dictating" affordance every voice app uses.
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    Circle().fill(isEnabled
                                  ? Color(red: 0.25, green: 0.55, blue: 1.0)
                                  : Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.4))
                )
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .overlay(progressRing)
    }

    @ViewBuilder
    private var progressRing: some View {
        if let progress = downloadProgress {
            ZStack {
                Circle()
                    .stroke(Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.18),
                            lineWidth: 3)
                Circle()
                    // Floor at a tiny sliver so the ring is visible the
                    // instant the download begins, even at fraction ≈ 0.
                    .trim(from: 0, to: max(0.015, progress))
                    .stroke(Color(red: 0.25, green: 0.55, blue: 1.0),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: progress)
            }
            .frame(width: 66, height: 66)
            .allowsHitTesting(false)
        }
    }

    private var accessibilityLabel: String {
        if let progress = downloadProgress {
            return "Downloading model, \(Int(progress * 100)) percent"
        }
        return "Start transcription"
    }

    private func start() {
        Task { try? await RecordingCoordinator.shared.recordAndTranscribe() }
    }
}

#Preview { ContentView() }

// MARK: - Toast (lightweight global success-message surface)
//
// Any view can publish a transient confirmation via `ToastManager.shared.show`.
// `ToastOverlay` is rendered once at the app root (in ContentView) and shows
// the latest message, auto-dismissing after a short delay. Lives in this file
// so it can be added without forcing an xcodegen regeneration that blanks
// out the signing team selection.

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let systemImage: String
    }

    @Published private(set) var current: Toast?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String, systemImage: String = "checkmark.circle.fill",
              duration: TimeInterval = 1.8) {
        dismissTask?.cancel()
        let toast = Toast(message: message, systemImage: systemImage)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            current = toast
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    self?.current = nil
                }
            }
        }
    }
}

struct ToastOverlay: View {
    @ObservedObject private var manager = ToastManager.shared

    var body: some View {
        VStack {
            if let toast = manager.current {
                HStack(spacing: 10) {
                    Image(systemName: toast.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 1.0))
                    Text(toast.message)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}
