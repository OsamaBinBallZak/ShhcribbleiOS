import MessageUI
import SwiftUI
import UIKit

struct FeedbackListView: View {
    @ObservedObject private var store = FeedbackStore.shared
    @State private var showCapture = false
    @State private var selectedItem: FeedbackItem?
    @State private var editMode: EditMode = .inactive
    @State private var selectedIds: Set<URL> = []
    @State private var bulkBatch: BulkMailBatch?
    @State private var showNoMailAlert = false

    /// Identifiable wrapper around a list of feedback items so the bulk
    /// mail sheet can be presented via `.sheet(item:)` rather than
    /// `.sheet(isPresented:) + separate-array-state`. The latter raced
    /// the array-write against the sheet's content-closure evaluation
    /// and rendered an empty (white) sheet on first present — same
    /// class of bug as the capture-view sendNow path (feedback #1).
    private struct BulkMailBatch: Identifiable {
        let id = UUID()
        let items: [FeedbackItem]
    }

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
            if editMode == .active {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        withAnimation { editMode = .inactive }
                        selectedIds.removeAll()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startBulkSend(items: itemsForSelection)
                    } label: {
                        Label("Send \(selectedIds.count)", systemImage: "paperplane.fill")
                    }
                    .disabled(selectedIds.isEmpty)
                }
            } else {
                // Sprint 7 redesign: power-user actions (select-mode,
                // send-all) live behind a single "…" Menu in the toolbar
                // — they're rare-use, and competing with the primary "+"
                // record-new affordance was visually noisy. The "+"
                // record button stays as the top-trailing primary action.
                if !store.items.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button {
                                withAnimation { editMode = .active }
                            } label: {
                                Label("Select items…", systemImage: "checklist")
                            }
                            Button {
                                startBulkSend(items: store.items)
                            } label: {
                                Label("Send all (\(store.items.count))", systemImage: "paperplane.fill")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCapture = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .sheet(isPresented: $showCapture) {
            FeedbackCaptureView()
        }
        .sheet(item: $selectedItem) { item in
            FeedbackDetailView(item: item)
        }
        .sheet(item: $bulkBatch) { batch in
            FeedbackMailComposer(items: batch.items) { sent in
                // Mark each successfully-sent item; no delete prompt.
                // User keeps history on device per Harry's feedback
                // (backlog #6c) — the "Sent ✓" badge on each row
                // makes status visible without nagging.
                for item in sent {
                    store.markSent(item)
                }
                withAnimation { editMode = .inactive }
                selectedIds.removeAll()
                bulkBatch = nil
            }
            .ignoresSafeArea()
        }
        .alert("Mail not available", isPresented: $showNoMailAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Mail.app isn't set up on this device. To send feedback, configure a mail account in Settings → Mail.")
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
            // Leave selection mode behind so it doesn't persist if user
            // navigates back here later.
            editMode = .inactive
            selectedIds.removeAll()
        }
    }

    /// Materialise the currently-selected IDs into actual FeedbackItem
    /// records. Used by the bulk mail composer's `Send N` button.
    private var itemsForSelection: [FeedbackItem] {
        store.items.filter { selectedIds.contains($0.id) }
    }

    /// Stage the given items for the bulk-mail sheet. Used by both the
    /// edit-mode "Send N" button (selected items) and the toolbar
    /// paperplane button (all items). Guards on Mail being available;
    /// shows an alert if not.
    private func startBulkSend(items: [FeedbackItem]) {
        guard !items.isEmpty else { return }
        guard MFMailComposeViewController.canSendMail() else {
            showNoMailAlert = true
            return
        }
        bulkBatch = BulkMailBatch(items: items)
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
        List(selection: $selectedIds) {
            ForEach(store.items) { item in
                rowContainer(item: item)
                    .tag(item.id)
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

    /// In view mode, the row is a Button that opens the detail sheet.
    /// In edit mode, taps are intercepted by the List's selection
    /// binding (via the `.tag(item.id)` outside), so we render the row
    /// as plain content with no button gesture.
    @ViewBuilder
    private func rowContainer(item: FeedbackItem) -> some View {
        if editMode == .active {
            row(for: item)
        } else {
            Button {
                selectedItem = item
            } label: {
                row(for: item)
            }
            .buttonStyle(.plain)
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
                HStack(spacing: 8) {
                    Text(relativeDate(item.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if item.isSent {
                        SentBadge()
                    }
                }
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
    @ObservedObject private var store = FeedbackStore.shared
    @State private var showMailComposer = false
    @State private var mailUnavailableAlert = false

    /// Re-read the item from the store after a successful send so the
    /// sentAt badge updates without dismissing first. The original
    /// `item` is a value snapshot; the store mutates the on-disk record.
    private var currentItem: FeedbackItem {
        store.items.first(where: { $0.id == item.id }) ?? item
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if currentItem.isSent, let sentAt = currentItem.sentAt {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("Sent on \(sentAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

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

                    Button {
                        if MFMailComposeViewController.canSendMail() {
                            showMailComposer = true
                        } else {
                            mailUnavailableAlert = true
                        }
                    } label: {
                        Label(currentItem.isSent ? "Send again" : "Send to Tiuri", systemImage: "paperplane.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
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
            .sheet(isPresented: $showMailComposer) {
                FeedbackMailComposer(item: item) { sent in
                    // Mark sent — no delete prompt. Item stays in the
                    // list with a "Sent ✓" badge so the user retains a
                    // record of what they reported (backlog #6c).
                    for sentItem in sent {
                        store.markSent(sentItem)
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Mail not available", isPresented: $mailUnavailableAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Mail.app isn't set up on this device. Configure a mail account in Settings → Mail and try again.")
            }
        }
    }
}

/// Pill badge rendered on the right of each row when an item has been
/// sent (i.e. `FeedbackItem.isSent == true`). Visible status indicator
/// for Harry's complaint d) "no status indicator for sent vs not yet".
private struct SentBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption2)
            Text("Sent")
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.green.opacity(0.15), in: Capsule())
        .foregroundStyle(.green)
    }
}

// `FeedbackMailComposer` lives in its own file at
// `ShhhcribbleiOS/Features/Feedback/FeedbackMailComposer.swift`.

// FeedbackShareSheet (UIActivityViewController-based) removed 2026-05-20
// per Tiuri's feedback — the generic share sheet showed AirDrop/Files/
// Signal/etc. but no auto-emails-to-Tiuri option. Replaced by the
// MFMailComposeViewController path used everywhere else (per-item
// "Send to Tiuri" and toolbar paperplane "Send all").
