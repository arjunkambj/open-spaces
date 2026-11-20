import SpacesLive
import SwiftUI
import WidgetKit

/// The widget extension. It holds one thing: the Live Activity shown on the Lock Screen and
/// in the Dynamic Island while a meeting is recorded. It is drawn by `SpacesLive`.
@main
struct SpacesWidgets: WidgetBundle {
  var body: some Widget {
    MeetingActivityWidget()
  }
}

struct MeetingActivityWidget: Widget {
  var body: some WidgetConfiguration {
    MeetingActivity.configuration(stop: StopRecordingIntent())
  }
}
