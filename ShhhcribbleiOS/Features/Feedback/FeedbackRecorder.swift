import AVFoundation
import Foundation

/// Thin wrapper around `AVAudioRecorder` used only by the feedback
/// capture flow. Records a temp WAV; caller transcribes it via
/// `TextEngine.transcribeOneShot` and then calls `discard()` to clean
/// up the file. Completely separate from the main `AudioInput` capture
/// pipeline — feedback recording is a one-shot batch flow with its own
/// session category (`.record`) and no warm-mode interaction.
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
