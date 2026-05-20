import SwiftUI
import UIKit

struct FeedbackListView: View {
    @ObservedObject private var store = FeedbackStore.shared
    @State private var showCapture = false
    @State private var showShareSheet = false
    @State private var selectedItem: FeedbackItem?

    var body: some View {
        Group {
            if store.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showCapture = true
                    } label: {
                        Label("Record new feedback", systemImage: "mic.fill")
                    }
                    if !store.items.isEmpty {
                        Button {
                            showShareSheet = true
                        } label: {
                            Label("Share all feedback…", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
            }
        }
        .sheet(isPresented: $showCapture) {
            FeedbackCaptureView()
        }
        .sheet(isPresented: $showShareSheet) {
            FeedbackShareSheet(folder: store.feedbackRoot)
        }
        .sheet(item: $selectedItem) { item in
            FeedbackDetailView(item: item)
        }
        .onAppear {
            store.reload()
            // Hide the global play FAB while this screen is up — having
            // it visible next to our "+" button confuses users about
            // which one starts feedback recording.
            NoteFocus.shared.hideGlobalPlayFAB = true
        }
        .onDisappear {
            NoteFocus.shared.hideGlobalPlayFAB = false
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("No feedback yet")
                .font(.title3.weight(.semibold))
            Text("Record voice feedback about Shhhcribble. Add a screenshot if you like.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showCapture = true
            } label: {
                Label("Record feedback", systemImage: "mic.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var list: some View {
        List {
            ForEach(store.items) { item in
                Button {
                    selectedItem = item
                } label: {
                    row(for: item)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        store.delete(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func row(for item: FeedbackItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let img = item.screenshotImage {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 56, height: 56)
                    Image(systemName: "waveform")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.transcript.isEmpty ? (item.note.isEmpty ? "(empty)" : item.note) : item.transcript)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(relativeDate(item.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

private struct FeedbackDetailView: View {
    let item: FeedbackItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let img = item.screenshotImage {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .cornerRadius(10)
                    }

                    if !item.transcript.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Transcript").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                            Text(item.transcript).font(.body)
                        }
                    }

                    if !item.note.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Note").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                            Text(item.note).font(.body)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Captured").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.body).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// `UIActivityViewController` wrapper that shares the entire Feedback
/// directory. iOS will zip it automatically for AirDrop / Mail.
private struct FeedbackShareSheet: UIViewControllerRepresentable {
    let folder: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [folder], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
