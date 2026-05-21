import MessageUI
import SwiftUI
import UIKit

/// Modal capture for app feedback / bug reports.
///
/// Flow (Sprint 7 redesign — record → review → SEND):
///   1. User taps "Record" → AVAudioRecorder writes a temp WAV.
///   2. Tap "Stop" → audio file is transcribed in-place via TDT
///      (one-shot, doesn't touch the live recording pipeline).
///   3. User reviews the transcript, optionally pastes a screenshot
///      and/or types a note.
///   4. Tap **Send** → FeedbackStore persists metadata.json +
///      screenshot.png to Documents/Feedback/<uuid>/, then the mail
///      composer opens immediately. On successful send the item is
///      marked `sentAt = Date()` in the store. On cancel/fail the
///      item stays in the list as a draft so the user can retry from
///      FeedbackListView.
///
/// The previous "Save locally → maybe send later" workflow surfaced as
/// confusing UX in Harry's first-round testing feedback (backlog #6).
/// Default action is now Send; local persistence is implicit.
struct FeedbackCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = FeedbackRecorder()
    @State private var transcript: String = ""
    @State private var note: String = ""
    @State private var pastedImage: UIImage?
    @State private var phase: Phase = .idle
    @State private var errorMessage: String?

    @State private var pendingMailItem: FeedbackItem?
    @State private var showMailComposer = false
    @State private var showNoMailAlert = false

    enum Phase {
        case idle              // Not yet recording.
        case recording         // AVAudioRecorder writing the temp file.
        case transcribing      // Recording stopped, TDT pass in flight.
        case review            // Have transcript, user can edit + send.
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    recorderRow
                    if let msg = errorMessage {
                        Text(msg).font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Speak about what happened. Transcription stays on-device; no audio is uploaded anywhere.")
                }

                if phase == .review || !transcript.isEmpty {
                    Section("Transcript (editable)") {
                        TextField("Transcript", text: $transcript, axis: .vertical)
                            .lineLimit(3...10)
                    }
                }

                Section("Screenshot (optional)") {
                    if let img = pastedImage {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(uiImage: img)
                                .resizable().scaledToFit()
                                .frame(maxHeight: 200)
                                .cornerRadius(8)
                            Button("Remove screenshot", role: .destructive) {
                                pastedImage = nil
                            }.font(.caption)
                        }
                    } else {
                        Button(action: pasteScreenshot) {
                            Label("Paste screenshot from clipboard", systemImage: "doc.on.clipboard")
                        }
                    }
                }

                Section("Note (optional)") {
                    TextField("Anything to add?", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .navigationTitle("New feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Discard demoted: smaller, destructive tint, lives in
                // the cancellation slot but visually de-emphasises so
                // it isn't symmetric with Send. Harry's complaint (b)
                // was that Cancel and Save read as equivalent options.
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .destructive) {
                        recorder.discard()
                        dismiss()
                    } label: {
                        Text("Discard").font(.subheadline)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: sendNow) {
                        Label("Send", systemImage: "paperplane.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.body.weight(.semibold))
                    }
                    .disabled(!canSend)
                }
            }
            .sheet(isPresented: $showMailComposer) {
                if let item = pendingMailItem {
                    FeedbackMailComposer(item: item) { sent in
                        for sentItem in sent {
                            FeedbackStore.shared.markSent(sentItem)
                        }
                        // Dismiss the capture view either way. The item is
                        // already persisted; if the user cancelled the mail
                        // composer, the draft stays in the list to retry.
                        dismiss()
                    }
                    .ignoresSafeArea()
                }
            }
            .alert("Mail not available", isPresented: $showNoMailAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Mail.app isn't set up on this device. Your feedback is saved locally — open Settings → Mail to configure an account, then send from the Feedback list.")
            }
        }
        .interactiveDismissDisabled(phase == .recording || phase == .transcribing)
    }

    private var canSend: Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // Phase guard so Send is dimmed while the user is still recording
        // / mid-transcribe — sending an empty draft on accident wastes a
        // mail-composer round trip.
        guard phase != .recording, phase != .transcribing else { return false }
        return !trimmedTranscript.isEmpty || !trimmedNote.isEmpty
    }

    private var recorderRow: some View {
        // Whole-row Button so taps anywhere on the row trigger recording.
        // Tiuri called out 2026-05-20 that only-the-icon-tappable wasn't
        // discoverable.
        Button(action: toggleRecord) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(phase == .recording ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(phase == .recording ? .red : Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLine)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if phase == .recording || recorder.elapsed > 0 {
                        Text(formatTime(recorder.elapsed))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if phase == .transcribing {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(Rectangle())   // make the empty Spacer area tappable too
        }
        .buttonStyle(.plain)
        .disabled(phase == .transcribing)
    }

    private var statusLine: String {
        switch phase {
        // Distinct copy when transcript already exists: tapping again
        // APPENDS to it (per Tiuri's 2026-05-20 feedback — overwriting
        // the previous capture was unexpected).
        case .idle: return transcript.isEmpty ? "Tap to record" : "Tap to add more"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .review: return transcript.isEmpty ? "Done" : "Done — review below"
        }
    }

    private func toggleRecord() {
        switch phase {
        case .recording:
            stopAndTranscribe()
        case .idle, .review:
            startRecording()
        case .transcribing:
            break
        }
    }

    private func startRecording() {
        errorMessage = nil
        // Don't reset the prior transcript — subsequent recordings append
        // (Tiuri's 2026-05-20 feedback: overwriting on re-tap was
        // unexpected). User can clear / edit the transcript field
        // manually if they want a clean slate.
        do {
            try recorder.start()
            phase = .recording
        } catch {
            errorMessage = "Couldn't start: \(error.localizedDescription)"
        }
    }

    private func stopAndTranscribe() {
        recorder.stop()
        guard let url = recorder.finishedFileURL else {
            errorMessage = "Recording missing."
            phase = .idle
            return
        }
        phase = .transcribing
        // Capture existing transcript so the async transcribe can append to it.
        let existing = transcript
        Task {
            do {
                let text = try await TextEngine.shared.transcribeOneShot(audioFileURL: url)
                let filterOn = UserDefaults.standard.object(forKey: "filterFillerWords") as? Bool ?? true
                let afterFiller = filterOn ? FillerWordFilter.filter(text) : text
                let filtered = SubstitutionPass.apply(afterFiller, rules: SubstitutionPass.currentRules())
                await MainActor.run {
                    // Append: if there was already a transcript, join with a
                    // space + the new text. Otherwise this is the first
                    // recording so just take the filtered result as-is.
                    if existing.isEmpty {
                        transcript = filtered
                    } else if !filtered.isEmpty {
                        transcript = existing + " " + filtered
                    } else {
                        transcript = existing  // new recording produced nothing
                    }
                    phase = .review
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Transcribe failed: \(error.localizedDescription). You can still save with just a screenshot + note."
                    phase = .review
                }
            }
            // We don't need the temp WAV anymore — the transcript is what we keep.
            recorder.discard()
        }
    }

    private func pasteScreenshot() {
        if let img = UIPasteboard.general.image {
            pastedImage = img
            errorMessage = nil
        } else {
            errorMessage = "Clipboard has no image. Take a screenshot (Side + Volume Up), then come back and tap Paste."
        }
    }

    /// Save the in-progress capture to disk and open the mail composer
    /// immediately. On successful send, `FeedbackMailComposer.onSent`
    /// fires and the item is marked sent in the store. On cancel/fail,
    /// the item stays in the list as an unsent draft so the user can
    /// retry from FeedbackListView's row → detail → Send button.
    private func sendNow() {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = FeedbackStore.shared.save(
            transcript: trimmedTranscript,
            note: trimmedNote,
            screenshot: pastedImage,
            durationSeconds: recorder.elapsed
        )
        guard MFMailComposeViewController.canSendMail() else {
            // Item is persisted; user can configure Mail and retry from
            // the list. Surface the constraint and dismiss.
            showNoMailAlert = true
            return
        }
        pendingMailItem = item
        showMailComposer = true
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%01d:%02d", total / 60, total % 60)
    }
}

// `FeedbackRecorder` lives in its own file at
// `ShhhcribbleiOS/Features/Feedback/FeedbackRecorder.swift`.
