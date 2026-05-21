import MessageUI
import SwiftUI
import UIKit

/// Recipient for the "Send to Tiuri" action. Hardcoded for now — change
/// here when the recipient changes.
let feedbackRecipientEmail = "tiurihartog@icloud.com"

/// `MFMailComposeViewController` wrapper. Pre-fills:
/// - To: `feedbackRecipientEmail` (Tiuri)
/// - Subject: per-item if 1 item, "Shhhcribble feedback (N items)" if more
/// - Body: transcript + optional note + timestamp + device info, repeated
///   per item with a divider between them
/// - Attachments: one PNG per item that has a screenshot, plus a `.zip`
///   containing the raw `Documents/Feedback/<uuid>/` folders for
///   programmatic parsing on the receiving end.
///
/// The user can edit any of these before tapping Send. If they tap
/// Cancel, the sheet dismisses without sending. Either way the feedback
/// items stay in the local Feedback list — the caller decides via the
/// `onSent` callback whether to mark them as sent in the store.
struct FeedbackMailComposer: UIViewControllerRepresentable {
    let items: [FeedbackItem]
    /// Called from the mail-compose-finished delegate with the items
    /// that were actually sent. The list / capture view uses this to
    /// call `FeedbackStore.markSent(_:)` for each.
    var onSent: (([FeedbackItem]) -> Void)? = nil

    /// Convenience overload for the single-item detail-view button.
    init(item: FeedbackItem, onSent: (([FeedbackItem]) -> Void)? = nil) {
        self.items = [item]
        self.onSent = onSent
    }

    init(items: [FeedbackItem], onSent: (([FeedbackItem]) -> Void)? = nil) {
        self.items = items
        self.onSent = onSent
    }

    func makeCoordinator() -> Coordinator { Coordinator(items: items, onSent: onSent) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([feedbackRecipientEmail])

        if items.count == 1, let item = items.first {
            let snippet = item.transcript.isEmpty
                ? (item.note.isEmpty ? "(no transcript)" : String(item.note.prefix(40)))
                : String(item.transcript.prefix(40))
            vc.setSubject("Shhhcribble feedback — \(snippet)")
        } else {
            vc.setSubject("Shhhcribble feedback (\(items.count) items)")
        }

        var body = ""
        for (idx, item) in items.enumerated() {
            if items.count > 1 {
                body += "— Item \(idx + 1) of \(items.count) —\n\n"
            }
            if !item.transcript.isEmpty {
                body += "Transcript:\n\(item.transcript)\n\n"
            }
            if !item.note.isEmpty {
                body += "Note:\n\(item.note)\n\n"
            }
            body += "Captured: \(item.createdAt.formatted(date: .abbreviated, time: .standard))\n"
            if idx < items.count - 1 {
                body += "\n———\n\n"
            }
        }
        body += "\nDevice: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)\n"
        body += "App: Shhhcribble\n\n"
        body += "Raw data attached as feedback.zip — extract to get the original metadata.json + screenshot.png for each item."
        vc.setMessageBody(body, isHTML: false)

        // Build + attach a zip containing the original folders (metadata.json
        // + screenshot.png per item). Easier for the recipient to parse
        // programmatically than multiple loose attachments.
        if let zipData = Self.zipFeedbackItems(items) {
            let zipName = items.count == 1 ? "feedback.zip" : "feedback-\(items.count)-items.zip"
            vc.addAttachmentData(zipData, mimeType: "application/zip", fileName: zipName)
        }
        return vc
    }

    /// Stage selected feedback folders into a temp directory, then use
    /// `NSFileCoordinator`'s `.forUploading` option (Apple-blessed) to
    /// produce a zip archive of that directory. Returns the zip's raw
    /// `Data` ready to attach to MFMailComposeViewController. Cleans up
    /// the staging dirs on the way out.
    private static func zipFeedbackItems(_ items: [FeedbackItem]) -> Data? {
        guard !items.isEmpty else { return nil }
        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory.appendingPathComponent("feedback-stage-\(UUID().uuidString)", isDirectory: true)
        let stagingFolder = stagingRoot.appendingPathComponent("feedback", isDirectory: true)
        do {
            try fm.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer { try? fm.removeItem(at: stagingRoot) }

        // Copy each item's folder into the staging area, preserving the
        // UUID-named directory so the recipient sees the original layout.
        for item in items {
            let dst = stagingFolder.appendingPathComponent(item.folder.lastPathComponent, isDirectory: true)
            try? fm.copyItem(at: item.folder, to: dst)
        }

        // Apple's automatic zipping via NSFileCoordinator. The block
        // receives a URL pointing at a `.zip` file iOS created on demand.
        let coordinator = NSFileCoordinator()
        var zipData: Data?
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: stagingFolder, options: [.forUploading], error: &coordError) { zipURL in
            zipData = try? Data(contentsOf: zipURL)
        }
        return zipData
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let items: [FeedbackItem]
        let onSent: (([FeedbackItem]) -> Void)?

        init(items: [FeedbackItem], onSent: (([FeedbackItem]) -> Void)?) {
            self.items = items
            self.onSent = onSent
        }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            controller.dismiss(animated: true) { [items, onSent] in
                if result == .sent {
                    onSent?(items)
                }
            }
        }
    }
}
