import AVFoundation
import SwiftUI
import UIKit

/// Modal capture for app feedback / bug reports.
///
/// Flow:
///   1. User taps "Record" → AVAudioRecorder writes a temp WAV.
///   2. Tap "Stop" → audio file is transcribed in-place via TDT
///      (one-shot, doesn't touch the live recording pipeline).
///   3. User reviews the transcript, optionally pastes a screenshot
///      and/or types a note.
///   4. Save → FeedbackStore writes metadata.json + screenshot.png
///      to Documents/Feedback/<uuid>/. The temp WAV is deleted.
///
/// Pattern adapted from GFR_Field_Recorder's FeedbackRecordingView,
/// scaled down for a single-user dogfooding loop.
struct FeedbackCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = FeedbackRecorder()
    @State private var transcript: String = ""
    @State private var note: String = ""
    @State private var pastedImage: UIImage?
    @State private var phase: Phase = .idle
    @State private var errorMessage: String?

    enum Phase {
        case idle              // Not yet recording.
        case recording         // AVAudioRecorder writing the temp file.
        case transcribing      // Recording stopped, TDT pass in flight.
        case review            // Have transcript, user can edit + save.
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { recorder.discard(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(phase == .recording || phase == .transcribing)
    }

    private var recorderRow: some View {
        HStack(spacing: 12) {
            Button(action: toggleRecord) {
                ZStack {
                    Circle()
                        .fill(phase == .recording ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(phase == .recording ? .red : Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .disabled(phase == .transcribing)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusLine).font(.body.weight(.medium))
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
    }

    private var statusLine: String {
        switch phase {
        case .idle: return transcript.isEmpty ? "Tap to record" : "Re-record"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .review: return "Done — review below"
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
        // Reset prior transcript so a re-record doesn't leak into the new one.
        transcript = ""
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
        Task {
            do {
                let text = try await TranscriptionService.shared.transcribeOneShot(audioFileURL: url)
                let filterOn = UserDefaults.standard.object(forKey: "filterFillerWords") as? Bool ?? true
                let afterFiller = filterOn ? FillerWordFilter.filter(text) : text
                let filtered = SubstitutionPass.apply(afterFiller, rules: SubstitutionPass.currentRules())
                await MainActor.run {
                    transcript = filtered
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

    private func save() {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        FeedbackStore.shared.save(
            transcript: trimmedTranscript,
            note: trimmedNote,
            screenshot: pastedImage,
            durationSeconds: recorder.elapsed
        )
        dismiss()
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%01d:%02d", total / 60, total % 60)
    }
}

/// Thin wrapper around AVAudioRecorder used only by the feedback flow.
/// Records to a temp file; caller transcribes it and then calls
/// `discard()` to clean up.
@MainActor
final class FeedbackRecorder: ObservableObject {
    @Published var elapsed: TimeInterval = 0

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var tempURL: URL?

    var finishedFileURL: URL? { tempURL }

    func start() throws {
        // Stand-alone audio session config. Use `.record` (not playAndRecord)
        // since we never play audio in this flow. defaultToSpeaker harmless
        // because session isn't activated for playback.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("feedback-\(UUID().uuidString).wav")
        // Linear PCM 16 kHz mono — matches what TDT's internal converter
        // does anyway, and `AVAudioFile` reads it back trivially.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.record()
        audioRecorder = r
        tempURL = url
        elapsed = 0

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed += 0.1 }
        }
    }

    func stop() {
        audioRecorder?.stop()
        audioRecorder = nil
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func discard() {
        stop()
        if let url = tempURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempURL = nil
        elapsed = 0
    }
}
