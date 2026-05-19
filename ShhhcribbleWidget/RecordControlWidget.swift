import AppIntents
import ShhhcribbleShared
import SwiftUI
import WidgetKit

struct RecordControlWidget: ControlWidget {
    static let kind = "com.hendritiuri.shhhcribble.record"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Record", systemImage: "waveform")
            }
        }
        .displayName("Shhhcribble")
        .description("Start a Shhhcribble recording.")
    }
}
