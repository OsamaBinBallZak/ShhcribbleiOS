import Foundation
import SwiftData

@Model
final class Note {
    var id: UUID = UUID()
    var transcript: String = ""
    var title: String = ""
    var createdAt: Date = Date()
    var duration: TimeInterval = 0
    var triggerRaw: String = TriggerSource.manual.rawValue
    var tags: [String] = []
    // Reserved for v3 semantic search. Always nil in v1/v2 — present from
    // schema v1 to avoid a future migration.
    var embedding: Data? = nil

    init(
        transcript: String,
        title: String,
        duration: TimeInterval,
        trigger: TriggerSource,
        createdAt: Date = Date()
    ) {
        self.transcript = transcript
        self.title = title
        self.duration = duration
        self.triggerRaw = trigger.rawValue
        self.createdAt = createdAt
    }

    var trigger: TriggerSource {
        get { TriggerSource(rawValue: triggerRaw) ?? .manual }
        set { triggerRaw = newValue.rawValue }
    }
}

enum TriggerSource: String, Codable, Sendable {
    case controlCenter
    case airPods
    case backTap
    case actionButton
    case keyboard
    case manual
    case imported
}
