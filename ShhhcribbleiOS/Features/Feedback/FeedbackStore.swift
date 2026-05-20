import Foundation
import UIKit

/// File-based feedback storage. Each captured item lives at
/// `Documents/Feedback/<uuid>/`:
///
///     metadata.json   { createdAt, transcript, note, hasScreenshot, durationSeconds }
///     screenshot.png  (optional — pasted from the user's clipboard)
///
/// Audio is captured during recording but discarded once we have the
/// transcript — Tiuri wants the text, not the audio (per design
/// conversation 2026-05-20). Smaller files, easier to skim, easier to
/// pull off-device.
///
/// Access for later review:
/// - iPhone: Files → On My iPhone → Shhhcribble → Feedback (enabled
///   via `UIFileSharingEnabled = true` in Info.plist).
/// - Mac: `xcrun devicectl device copy from --domain-type
///   appDataContainer --domain-identifier com.hendritiuri.shhhcribble
///   --source /Documents/Feedback --destination <local>`.
/// - Within app: tap the share button in FeedbackListView to AirDrop
///   the whole Feedback directory.
///
/// File-based on purpose (not SwiftData):
/// - Short-lived items, no schema evolution likely.
/// - Direct file access is the whole point — we want to read these
///   externally on the Mac.
/// - No migration risk if we change `Feedback` shape.
@MainActor
final class FeedbackStore: ObservableObject {
    static let shared = FeedbackStore()

    @Published private(set) var items: [FeedbackItem] = []

    private let root: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.root = docs.appendingPathComponent("Feedback", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    var feedbackRoot: URL { root }

    var count: Int { items.count }

    func reload() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            items = []
            return
        }
        items = entries
            .compactMap { url -> FeedbackItem? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
                return FeedbackItem.load(from: url)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Save a new feedback item. Returns the folder URL so the caller
    /// can optionally drop a screenshot into it separately.
    @discardableResult
    func save(
        transcript: String,
        note: String,
        screenshot: UIImage?,
        durationSeconds: Double
    ) -> URL {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var hasScreenshot = false
        if let img = screenshot, let pngData = img.pngData() {
            try? pngData.write(to: folder.appendingPathComponent("screenshot.png"))
            hasScreenshot = true
        }

        let metadata: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "transcript": transcript,
            "note": note,
            "hasScreenshot": hasScreenshot,
            "durationSeconds": durationSeconds,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
            try? data.write(to: folder.appendingPathComponent("metadata.json"))
        }
        reload()
        return folder
    }

    func delete(_ item: FeedbackItem) {
        try? FileManager.default.removeItem(at: item.folder)
        reload()
    }
}

struct FeedbackItem: Identifiable, Hashable {
    let folder: URL
    let createdAt: Date
    let transcript: String
    let note: String
    let hasScreenshot: Bool
    let durationSeconds: Double

    var id: URL { folder }
    var screenshotURL: URL { folder.appendingPathComponent("screenshot.png") }

    var screenshotImage: UIImage? {
        guard hasScreenshot else { return nil }
        return UIImage(contentsOfFile: screenshotURL.path)
    }

    static func load(from folder: URL) -> FeedbackItem? {
        let metadataURL = folder.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let createdAtRaw = json["createdAt"] as? String ?? ""
        let createdAt = ISO8601DateFormatter().date(from: createdAtRaw) ?? Date()
        return FeedbackItem(
            folder: folder,
            createdAt: createdAt,
            transcript: json["transcript"] as? String ?? "",
            note: json["note"] as? String ?? "",
            hasScreenshot: json["hasScreenshot"] as? Bool ?? false,
            durationSeconds: json["durationSeconds"] as? Double ?? 0
        )
    }
}
