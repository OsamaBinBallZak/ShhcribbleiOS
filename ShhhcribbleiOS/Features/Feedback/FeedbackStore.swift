import Foundation
import UIKit

/// File-based feedback storage. Each captured item lives at
/// `Documents/Feedback/<uuid>/`:
///
///     metadata.json   { createdAt, transcript, note, hasScreenshot, durationSeconds, sentAt? }
///     screenshot.png  (optional — pasted from the user's clipboard)
///
/// `sentAt` (Codable optional) tracks whether the item has been emailed
/// to the recipient. Nil for drafts, populated on successful mail send.
/// Used by the list view to render a "Sent ✓" badge.
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
        dedupeOnce()
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

    /// Save a new feedback item. Returns the persisted item so the caller
    /// can stage it for sending or grab its folder URL.
    @discardableResult
    func save(
        transcript: String,
        note: String,
        screenshot: UIImage?,
        durationSeconds: Double
    ) -> FeedbackItem {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var hasScreenshot = false
        if let img = screenshot, let pngData = img.pngData() {
            try? pngData.write(to: folder.appendingPathComponent("screenshot.png"))
            hasScreenshot = true
        }

        let metadata = FeedbackMetadata(
            createdAt: Date(),
            transcript: transcript,
            note: note,
            hasScreenshot: hasScreenshot,
            durationSeconds: durationSeconds,
            sentAt: nil
        )
        metadata.write(to: folder)
        reload()
        return items.first { $0.folder == folder } ?? FeedbackItem(folder: folder, metadata: metadata)
    }

    /// Mark an item as sent. Persists `sentAt = Date()` to its metadata.json
    /// and reloads so the list view sees the new flag. Idempotent — if the
    /// item is already marked sent, the existing timestamp is preserved
    /// (re-sends don't bump the "first sent" record).
    func markSent(_ item: FeedbackItem) {
        guard item.sentAt == nil else { return }
        var metadata = item.metadata
        metadata.sentAt = Date()
        metadata.write(to: item.folder)
        reload()
    }

    func delete(_ item: FeedbackItem) {
        try? FileManager.default.removeItem(at: item.folder)
        reload()
    }

    /// One-shot cleanup for the sent+unsent duplicate pairs that landed
    /// on devices before the 2026-05-24 white-sheet fix. Pairs the user
    /// already had on disk look like: same transcript, createdAt within
    /// ~10s of each other, one with `sentAt` and one without. Keep the
    /// sent copy (canonical record of what was emailed) and delete the
    /// drafty twin. Gated by a UserDefaults flag so it runs exactly once.
    private static let dedupeFlagKey = "feedbackDedupRunAt2026-05-24"

    private func dedupeOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.dedupeFlagKey) else { return }
        defer { defaults.set(true, forKey: Self.dedupeFlagKey) }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return
        }
        let all: [FeedbackItem] = entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            return FeedbackItem.load(from: url)
        }

        // Group by transcript. For each group, walk by createdAt and
        // collapse runs of items where consecutive entries are <=10s
        // apart. Within a run, the sent copy wins; otherwise keep the
        // oldest (the original draft).
        let byTranscript = Dictionary(grouping: all, by: { $0.transcript })
        for (_, group) in byTranscript where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            var run: [FeedbackItem] = []
            for item in sorted {
                if let last = run.last, item.createdAt.timeIntervalSince(last.createdAt) <= 10 {
                    run.append(item)
                } else {
                    collapseRun(run)
                    run = [item]
                }
            }
            collapseRun(run)
        }
    }

    private func collapseRun(_ run: [FeedbackItem]) {
        guard run.count > 1 else { return }
        let keeper = run.first(where: { $0.isSent }) ?? run.first!
        for item in run where item.id != keeper.id {
            try? FileManager.default.removeItem(at: item.folder)
        }
    }
}

/// On-disk schema for `metadata.json`. Codable so reads + writes share
/// one definition. `sentAt` is optional — pre-2026-05-21 items don't have
/// the key; Codable's `decodeIfPresent` returns nil for those, which is
/// correct (they were created before sent-tracking existed and we don't
/// know whether they were sent).
struct FeedbackMetadata: Codable {
    let createdAt: Date
    let transcript: String
    let note: String
    let hasScreenshot: Bool
    let durationSeconds: Double
    var sentAt: Date?

    private static let iso = ISO8601DateFormatter()

    private static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        // Match the original wire format (ISO8601) so existing items
        // continue to read after the Codable migration.
        enc.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso.string(from: date))
        }
        return enc
    }

    private static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            return iso.date(from: raw) ?? Date()
        }
        return dec
    }

    static func load(from folder: URL) -> FeedbackMetadata? {
        let url = folder.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(FeedbackMetadata.self, from: data)
    }

    func write(to folder: URL) {
        guard let data = try? Self.makeEncoder().encode(self) else { return }
        try? data.write(to: folder.appendingPathComponent("metadata.json"))
    }
}

struct FeedbackItem: Identifiable, Hashable {
    let folder: URL
    let metadata: FeedbackMetadata

    var id: URL { folder }
    var createdAt: Date { metadata.createdAt }
    var transcript: String { metadata.transcript }
    var note: String { metadata.note }
    var hasScreenshot: Bool { metadata.hasScreenshot }
    var durationSeconds: Double { metadata.durationSeconds }
    var sentAt: Date? { metadata.sentAt }
    var isSent: Bool { metadata.sentAt != nil }

    var screenshotURL: URL { folder.appendingPathComponent("screenshot.png") }

    var screenshotImage: UIImage? {
        guard hasScreenshot else { return nil }
        return UIImage(contentsOfFile: screenshotURL.path)
    }

    static func load(from folder: URL) -> FeedbackItem? {
        guard let metadata = FeedbackMetadata.load(from: folder) else { return nil }
        return FeedbackItem(folder: folder, metadata: metadata)
    }

    static func == (lhs: FeedbackItem, rhs: FeedbackItem) -> Bool {
        lhs.folder == rhs.folder && lhs.sentAt == rhs.sentAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(folder)
    }
}
