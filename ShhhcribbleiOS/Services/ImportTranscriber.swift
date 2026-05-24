import AVFoundation
import Foundation
import UIKit
import os

private let importLog = Logger(subsystem: "com.shhhcribble.diag", category: "import")

/// Handles the "share an audio file into Shhhcribble" flow (feedback #5).
/// iOS routes audio files into the app via `.onOpenURL`. This actor takes
/// the URL, copies the file into our sandbox (security-scoped resources
/// don't survive past the open callback), claims background runtime so a
/// backgrounded app can finish, runs `TextEngine.transcribeOneShot`, runs
/// the same vocabulary pass the live pipeline uses, then inserts a Note
/// via `NotesRepository`.
///
/// One in-flight import at a time — concurrent imports could race the
/// background-task slot. The toast / banner UI tells the user about it.
actor ImportTranscriber {
    static let shared = ImportTranscriber()

    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var inFlight = false

    private init() {}

    /// Returns true if iOS handed us a file URL we should treat as an
    /// audio import. Cheap path-extension sniff — TextEngine's
    /// `transcribeOneShot` uses `AVAudioFile`, which accepts any format
    /// AVFoundation can decode (m4a, mp3, wav, aif, caf, …).
    static func looksLikeAudio(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        return [
            "m4a", "mp3", "wav", "aif", "aiff", "caf",
            "aac", "mp4", "ogg", "opus", "flac",
        ].contains(ext)
    }

    func importAndTranscribe(from sourceURL: URL) async {
        if inFlight {
            await MainActor.run {
                ToastManager.shared.show("Already importing — try again in a moment", systemImage: "hourglass")
            }
            return
        }
        inFlight = true
        defer {
            inFlight = false
            endBackgroundTask()
        }

        beginBackgroundTask()
        await MainActor.run {
            ToastManager.shared.show("Transcribing imported audio…", systemImage: "waveform.badge.magnifyingglass", duration: 4.0)
        }

        // 1) Copy into our sandbox. The security-scoped URL iOS hands us
        //    only stays valid for the open-document callback; copying
        //    eagerly lets the rest of this method run without scope
        //    bookkeeping. Imports/ is also what Files.app surfaces, so
        //    the user can see what they brought in.
        let localURL: URL
        do {
            localURL = try copyIntoSandbox(sourceURL)
        } catch {
            importLog.error("import: copy failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                ToastManager.shared.show("Couldn't read that audio file", systemImage: "exclamationmark.triangle")
            }
            return
        }

        // 2) Duration via AVAudioFile for the Note metadata. Cheap — just
        //    reads the header.
        let duration = (try? readDuration(localURL)) ?? 0

        // 3) Transcribe. `transcribeOneShot` returns raw TDT text; we run
        //    the same filler + substitution pass the live recording
        //    pipeline does so imported notes follow the user's vocabulary.
        let raw: String
        do {
            raw = try await TextEngine.shared.transcribeOneShot(audioFileURL: localURL)
        } catch {
            importLog.error("import: transcribe failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                ToastManager.shared.show("Transcription failed", systemImage: "exclamationmark.triangle")
            }
            return
        }

        let filterOn = UserDefaults.standard.object(forKey: "filterFillerWords") as? Bool ?? true
        let afterFiller = filterOn ? FillerWordFilter.filter(raw) : raw
        let final = SubstitutionPass.apply(afterFiller, rules: SubstitutionPass.currentRules())

        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await MainActor.run {
                ToastManager.shared.show("No speech detected in that audio", systemImage: "waveform.slash")
            }
            return
        }

        // 4) Insert via NotesRepository — same path as a live recording.
        await MainActor.run {
            NotesRepository.shared.insert(
                transcript: final,
                duration: duration,
                trigger: .imported
            )
            ToastManager.shared.show("Imported", systemImage: "square.and.arrow.down.fill")
        }
    }

    // MARK: - Helpers

    private func copyIntoSandbox(_ sourceURL: URL) throws -> URL {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let importsDir = docs.appendingPathComponent("Imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: importsDir, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension
        let dest = importsDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return dest
    }

    private func readDuration(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let frameCount = Double(file.length)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return frameCount / sampleRate
    }

    private func beginBackgroundTask() {
        let id = UIApplication.shared.beginBackgroundTask(withName: "Shhhcribble.import") { [weak self] in
            Task { await self?.forceEndBackgroundTask() }
        }
        self.bgTaskId = id
    }

    private func endBackgroundTask() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }

    private func forceEndBackgroundTask() {
        endBackgroundTask()
    }
}
