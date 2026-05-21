import MessageUI
import SwiftUI
import UIKit

struct FeedbackListView: View {
    @ObservedObject private var store = FeedbackStore.shared
    @State private var showCapture = false
    @State private var selectedItem: FeedbackItem?
    @State private var editMode: EditMode = .inactive
    @State private var selectedIds: Set<URL> = []
    @State private var showBulkMail = false
    @State private var bulkMailItems: [FeedbackItem] = []
    @State private var justSentItems: [FeedbackItem] = []
    @State private var showDeleteAfterSend = false
    @State private var showNoMailAlert = false

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
                if !store.items.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Select") {
                            withAnimation { editMode = .active }
                        }
                    }
                }
                // Send-all button (only when items exist) + record-new
                // button as separate top-trailing items. Tiuri called out
                // 2026-05-20 that a combined Menu reading "either share or
                // record" was confusing — they're unrelated actions.
                if !store.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            startBulkSend(items: store.items)
                        } label: {
                            Image(systemName: "paperplane.fill")
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
        .sheet(isPresented: $showBulkMail) {
            FeedbackMailComposer(items: bulkMailItems) { sent in
                justSentItems = sent
                // Show the delete prompt on the next runloop tick — the
                // sheet's own dismiss animation needs to finish first or
                // the alert mounts behind the disappearing sheet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showDeleteAfterSend = true
                }
            }
            .ignoresSafeArea()
        }
        .alert("Mail not available", isPresented: $showNoMailAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Mail.app isn't set up on this device. To send feedback, configure a mail account in Settings → Mail.")
        }
        .alert("Sent — delete from device?", isPresented: $showDeleteAfterSend) {
            Button("Keep", role: .cancel) {
                justSentItems = []
            }
            Button("Delete", role: .destructive) {
                for item in justSentItems {
                    store.delete(item)
                }
                justSentItems = []
                withAnimation { editMode = .inactive }
                selectedIds.removeAll()
            }
        } message: {
            Text("\(justSentItems.count) feedback item\(justSentItems.count == 1 ? "" : "s") sent. Delete from this device now?")
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
    /// records. Used by the bulk mail composer + the post-send delete
    /// flow.
    private var itemsForSelection: [FeedbackItem] {
        store.items.filter { selectedIds.contains($0.id) }
    }

    // Note: post-send → delete-prompt handoff happens via the
    // `onSent` callback on FeedbackMailComposer, not onDismiss, so
    // we can distinguish a sent vs cancelled flow.

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
        bulkMailItems = items
        showBulkMail = true
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
    @ObservedObject private var store = FeedbackStore.shared
    @State private var showMailComposer = false
    @State private var mailUnavailableAlert = false
    @State private var showDeleteAfterSend = false

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

                    Button {
                        if MFMailComposeViewController.canSendMail() {
                            showMailComposer = true
                        } else {
                            mailUnavailableAlert = true
                        }
                    } label: {
                        Label("Send to Tiuri", systemImage: "paperplane.fill")
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
                FeedbackMailComposer(item: item) { _ in
                    // Successful send — prompt to delete on the next runloop
                    // tick after the sheet finishes dismissing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showDeleteAfterSend = true
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Mail not available", isPresented: $mailUnavailableAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Mail.app isn't set up on this device. Use the Share button in the list to send via another app.")
            }
            .alert("Sent — delete from device?", isPresented: $showDeleteAfterSend) {
                Button("Keep", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    store.delete(item)
                    dismiss()
                }
            } message: {
                Text("Feedback sent. Delete from this device now?")
            }
        }
    }
}

// `FeedbackMailComposer` lives in its own file at
// `ShhhcribbleiOS/Features/Feedback/FeedbackMailComposer.swift`.

// FeedbackShareSheet (UIActivityViewController-based) removed 2026-05-20
// per Tiuri's feedback — the generic share sheet showed AirDrop/Files/
// Signal/etc. but no auto-emails-to-Tiuri option. Replaced by the
// MFMailComposeViewController path used everywhere else (per-item
// "Send to Tiuri" and toolbar paperplane "Send all").
