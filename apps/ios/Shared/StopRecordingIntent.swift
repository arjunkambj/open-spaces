import AppIntents
import WisperLive

/// Stops the meeting that is being recorded. It is the Stop button on the Lock Screen and
/// in the Dynamic Island.
///
/// This file is compiled into the app and into the widget extension. The widget draws the
/// button; iOS runs `perform` in the app, because the intent is a `LiveActivityIntent`.
/// The app says what stopping means in `MeetingActivity.stopRecording`.
struct StopRecordingIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop Recording"
  // Shortcuts has its own "Stop Meeting Recording", which also says what happened.
  static let isDiscoverable = false

  @MainActor
  func perform() async throws -> some IntentResult {
    await MeetingActivity.stopRecording()
    return .result()
  }
}
