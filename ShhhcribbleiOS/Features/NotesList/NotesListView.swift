import SwiftData
import SwiftUI
import UIKit

struct NotesListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Note.createdAt, order: .reverse) private var notes: [Note]
    @State private var searchText: String = ""
    @State private var selectedTags: Set<String> = []

    private var allTags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for note in notes {
            for tag in note.tags where !seen.contains(tag) {
                seen.insert(tag)
                out.append(tag)
            }
        }
        return out.sorted()
    }

    private var filteredNotes: [Note] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.lowercased()
        return notes.filter { note in
            if !selectedTags.isEmpty {
                guard selectedTags.isSubset(of: Set(note.tags)) else { return false }
            }
            if !needle.isEmpty {
                guard
                    note.transcript.lowercased().contains(needle)
                        || note.title.lowercased().contains(needle)
                else { return false }
            }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Notes")
                        .font(.system(size: 32, weight: .bold))
                    Spacer()
                    if !notes.isEmpty {
                        Button("Clear All", role: .destructive, action: clearAll)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

                if !notes.isEmpty {
                    SearchBar(text: $searchText)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                if !allTags.isEmpty {
                    TagFilterBar(
                        tags: allTags,
                        selected: $selectedTags
                    )
                    .padding(.bottom, 8)
                }

                if notes.isEmpty {
                    Spacer()
                    NotesEmptyState()
                    Spacer()
                } else if filteredNotes.isEmpty {
                    Spacer()
                    ContentUnavailableView.search(text: searchText)
                    Spacer()
                } else {
                    List {
                        ForEach(filteredNotes) { note in
                            NavigationLink(value: note) {
                                NoteRow(note: note,
                                        onCopy: { copy(note) },
                                        onDelete: { delete(note) })
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Note.self) { note in
                NoteDetailView(note: note)
            }
        }
    }

    private func copy(_ note: Note) {
        UIPasteboard.general.string = note.transcript
        ToastManager.shared.show("Copied to clipboard", systemImage: "doc.on.doc.fill")
    }

    private func delete(_ note: Note) {
        context.delete(note)
        try? context.save()
    }

    private func clearAll() {
        selectedTags.removeAll()
        for note in notes {
            context.delete(note)
        }
        try? context.save()
    }
}

private struct TagFilterBar: View {
    let tags: [String]
    @Binding var selected: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    let isOn = selected.contains(tag)
                    Button {
                        if isOn { selected.remove(tag) } else { selected.insert(tag) }
                    } label: {
                        HStack(spacing: 4) {
                            if isOn {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            Text(tag)
                                .font(.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                isOn ? Color.accentColor.opacity(0.25)
                                     : Color(.tertiarySystemFill)
                            )
                        )
                        .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }

                if !selected.isEmpty {
                    Button("Clear filters") {
                        selected.removeAll()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct SearchBar: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search notes", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }
}

private struct NoteRow: View {
    let note: Note
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.transcript)
                    .foregroundStyle(.primary)
                    .lineLimit(5)
                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 1.0))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.12))
                    )
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy transcript")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Empty-state view shown when the user has zero saved notes.
///
/// Reads `TranscriptionStatus.shared` so the copy adapts to whatever
/// the transcription engine is currently doing — which on first launch
/// is "downloading the 494 MB model" for several minutes. Without this
/// adaptation, the user sees "Tap the mic to start" while the FAB is
/// silently disabled and concludes the app is broken (Harry's first-
/// launch confusion, FB-4 + Tiuri's expanded diagnosis 2026-05-21).
///
/// The FAB's own progress ring is kept as a secondary indicator; the
/// empty state carries the main explanation.
private struct NotesEmptyState: View {
    @StateObject private var status = TranscriptionStatus.shared

    var body: some View {
        switch status.model {
        case .notLoaded:
            ContentUnavailableView(
                "Setting up Shhhcribble",
                systemImage: "gearshape",
                description: Text("Preparing the transcription engine…")
            )
        case .loading:
            if let progress = status.modelDownloadProgress {
                downloadingView(progress: progress)
            } else if let step = status.modelCompileStep, let total = status.modelCompileTotal {
                compilingView(step: step, total: total, modelName: status.modelCompileName)
            } else {
                ContentUnavailableView(
                    "Almost ready",
                    systemImage: "gearshape",
                    description: Text("Setting up the transcription engine…")
                )
            }
        case .ready:
            ContentUnavailableView(
                "No notes yet",
                systemImage: "waveform",
                description: Text("Tap the mic to start your first voice note.")
            )
        case .error(let detail):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.red)
                Text("Couldn't set up transcription")
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    Task { await RecordingCoordinator.shared.reloadModel() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func compilingView(step: Int, total: Int, modelName: String?) -> some View {
        CompilingProgressView(step: step, total: total, modelName: modelName)
    }

    @ViewBuilder
    private func downloadingView(progress: Double) -> some View {
        VStack(spacing: 16) {
            // Big circular progress ring so the percentage is unmissable.
            // Replaces the FAB's small ring as the primary "we're doing
            // something" indicator during first-launch download.
            ZStack {
                Circle()
                    .stroke(Color(.tertiarySystemFill), lineWidth: 6)
                    .frame(width: 72, height: 72)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 72, height: 72)
                Text("\(Int(progress * 100))%")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            Text("Downloading transcription engine")
                .font(.title3.weight(.semibold))
            Text("First-time setup — about 494 MB. Runs on-device after this; no audio ever leaves your phone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

/// Determinate progress ring + an "ant" arc continuously running around
/// the ring border. The static blue arc reflects step/total honestly
/// (so the user can read it as a real fraction). The thin bright "ant"
/// — a small 10% arc orbiting the ring — gives a clearly-active signal
/// independent of progress so even when the step counter is stuck on
/// the slow Encoder model (~25 s) the user still sees motion.
///
/// Extracted from `NotesEmptyState` because the `@State`-driven
/// animation needs its own view that can own the animation lifecycle.
private struct CompilingProgressView: View {
    let step: Int
    let total: Int
    let modelName: String?

    @State private var rotation: Double = -90  // start at 12 o'clock

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                // Background track
                Circle()
                    .stroke(Color(.tertiarySystemFill), lineWidth: 6)
                    .frame(width: 72, height: 72)

                // Single arc whose length = step/total AND that
                // continuously rotates. Carries both the progress
                // (length) and the "alive" signal (rotation) in one
                // visual element so the UI isn't competing with itself.
                Circle()
                    .trim(from: 0, to: min(1.0, Double(step) / Double(total)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
                    .frame(width: 72, height: 72)

                Text("\(step)/\(total)")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            Text("Compiling transcription engine")
                .font(.title3.weight(.semibold))
            Group {
                if let modelName {
                    Text("Compiling \(modelName) model… first launch can take ~25 seconds for the largest step.")
                } else {
                    Text("First launch can take ~25 seconds.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
        .onAppear {
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                rotation = 270  // -90 + 360
            }
        }
    }
}
