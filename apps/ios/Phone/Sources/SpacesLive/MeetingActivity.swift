#if os(iOS)
  import ActivityKit
  import AppIntents
  import SwiftUI
  import WidgetKit
  import SpacesDomain
  import SpacesUI

  /// What a meeting's Live Activity is made from.
  public struct MeetingActivityAttributes: ActivityAttributes {
    /// The part that can change while the meeting is recorded.
    public struct ContentState: Codable, Hashable, Sendable {
      public var title: String

      public init(title: String) {
        self.title = title
      }
    }

    public var startedAt: Date

    public init(startedAt: Date) {
      self.startedAt = startedAt
    }
  }

  /// Shows on the Lock Screen and in the Dynamic Island that a meeting is being recorded.
  ///
  /// The app calls `show` when a recording starts (and again if its title changes) and
  /// `end` when it stops. Both are safe to call at any time, in any order.
  public enum MeetingActivity {
    /// Puts the recording on the Lock Screen and in the Dynamic Island, or updates it.
    /// Does nothing when the person has turned Live Activities off.
    public static func show(title: String, startedAt: Date) async {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      let content = ActivityContent(
        state: MeetingActivityAttributes.ContentState(title: title),
        staleDate: nil
      )
      let running = Activity<MeetingActivityAttributes>.activities
      if let current = running.first(where: { $0.attributes.startedAt == startedAt }) {
        await current.update(content)
        return
      }
      for stale in running {
        await stale.end(nil, dismissalPolicy: .immediate)
      }
      // iOS refuses this when the app is not on screen. Then there is simply no banner.
      _ = try? Activity<MeetingActivityAttributes>.request(
        attributes: MeetingActivityAttributes(startedAt: startedAt),
        content: content
      )
    }

    /// Takes the recording off the Lock Screen and out of the Dynamic Island. Also clears
    /// one left behind by a crash.
    public static func end() async {
      for activity in Activity<MeetingActivityAttributes>.activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
    }
  }

  extension MeetingActivity {
    /// What the Stop button on the Lock Screen does. The app sets it once, when it starts.
    ///
    /// The button is drawn by the widget extension but runs in the app (see `configuration`),
    /// and this package cannot see the app. So the app hands in the work here.
    @MainActor public static var stopRecording: @MainActor @Sendable () async -> Void = {}

    /// The Live Activity itself, for the widget extension to show in a `Widget`.
    ///
    /// - stop: the intent behind the Stop button. Make it a `LiveActivityIntent` that both
    ///   the app and the widget extension compile: iOS then runs it in the app, which is
    ///   the only place a recording can be stopped. A link would not do, because the app
    ///   does not let a link stop a recording.
    @MainActor
    public static func configuration(stop: some LiveActivityIntent) -> some WidgetConfiguration {
      ActivityConfiguration(for: MeetingActivityAttributes.self) { context in
        MeetingBanner(title: context.state.title, startedAt: context.attributes.startedAt) {
          StopButton(intent: stop)
        }
        .activityBackgroundTint(Spaces.Color.panel)
        .activitySystemActionForegroundColor(Spaces.Color.textPrimary)
      } dynamicIsland: { context in
        // The island is black in light mode and in dark, so its text keeps the system's
        // own fonts and white instead of the Spaces text styles.
        DynamicIsland {
          DynamicIslandExpandedRegion(.leading) {
            RecordingMark(size: 36)
          }
          DynamicIslandExpandedRegion(.trailing) {
            MeetingClock(startedAt: context.attributes.startedAt)
              .font(.title3)
              .frame(maxWidth: 72, alignment: .trailing)
          }
          DynamicIslandExpandedRegion(.center) {
            Text(context.state.title)
              .font(.headline)
              .lineLimit(1)
          }
          DynamicIslandExpandedRegion(.bottom) {
            StopButton(intent: stop)
          }
        } compactLeading: {
          RecordingMark(size: 22)
        } compactTrailing: {
          MeetingClock(startedAt: context.attributes.startedAt)
            .font(.caption)
            .frame(maxWidth: 44, alignment: .trailing)
        } minimal: {
          RecordingMark(size: 22)
        }
        .widgetURL(SpacesLink.showHub.url)
        .keylineTint(Spaces.Color.recording)
      }
    }
  }

  /// A button that runs `intent` and looks like `StopLabel`.
  private struct StopButton<Intent: LiveActivityIntent>: View {
    let intent: Intent

    var body: some View {
      Button(intent: intent) { StopLabel() }
        .buttonStyle(.plain)
    }
  }
#endif
