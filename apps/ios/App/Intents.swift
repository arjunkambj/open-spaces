import AppIntents
import SpacesPhone

// What Spaces offers to Shortcuts, Siri, Spotlight and the Action button.
// Each intent is one call into `PhoneSession`; nothing is decided here.

/// Opens the app on the Dictate tab, already listening.
struct StartDictationIntent: AppIntent {
  static let title: LocalizedStringResource = "Start Dictation"
  static let description = IntentDescription("Opens Spaces and starts listening.")
  // iOS only lets the app that is on screen start the microphone.
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    await PhoneSession.shared.startDictation()
    return .result()
  }
}

/// Opens the app and starts recording a meeting.
struct StartMeetingIntent: AppIntent {
  static let title: LocalizedStringResource = "Start Meeting Recording"
  static let description = IntentDescription("Opens Spaces and starts recording a meeting.")
  static let openAppWhenRun = true

  @Parameter(title: "Title", description: "A name for the meeting. Leave empty and Spaces names it.")
  var meetingTitle: String?

  @MainActor
  func perform() async throws -> some IntentResult {
    await PhoneSession.shared.startMeeting(title: meetingTitle)
    return .result()
  }
}

/// Stops the meeting that is being recorded, without opening the app.
struct StopMeetingIntent: AppIntent {
  static let title: LocalizedStringResource = "Stop Meeting Recording"
  static let description = IntentDescription(
    "Stops the meeting Spaces is recording and writes its notes."
  )

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let stopped = await PhoneSession.shared.stopMeeting()
    let dialog: IntentDialog =
      stopped ? "Stopped. Your notes are being written." : "No meeting is being recorded."
    return .result(dialog: dialog)
  }
}

/// Puts the most recent dictation on the clipboard, without opening the app.
struct CopyLastDictationIntent: AppIntent {
  static let title: LocalizedStringResource = "Copy Last Dictation"
  static let description = IntentDescription("Copies your most recent dictation, ready to paste.")

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let copied = await PhoneSession.shared.copyLastDictation()
    let dialog: IntentDialog = copied ? "Copied." : "There is no dictation to copy yet."
    return .result(dialog: dialog)
  }
}

/// The shortcuts that exist from the moment the app is installed, with what to say to Siri.
struct SpacesShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartDictationIntent(),
      phrases: [
        "Start dictation in \(.applicationName)",
        "Dictate with \(.applicationName)",
        "Take a note with \(.applicationName)",
      ],
      shortTitle: "Start Dictation",
      systemImageName: "mic.fill"
    )
    AppShortcut(
      intent: StartMeetingIntent(),
      phrases: [
        "Start a meeting in \(.applicationName)",
        "Record a meeting with \(.applicationName)",
      ],
      shortTitle: "Record Meeting",
      systemImageName: "record.circle"
    )
    AppShortcut(
      intent: StopMeetingIntent(),
      phrases: [
        "Stop the meeting in \(.applicationName)",
        "Stop recording in \(.applicationName)",
      ],
      shortTitle: "Stop Meeting",
      systemImageName: "stop.circle"
    )
    AppShortcut(
      intent: CopyLastDictationIntent(),
      phrases: [
        "Copy my last dictation from \(.applicationName)",
        "Copy the last thing I said in \(.applicationName)",
      ],
      shortTitle: "Copy Last Dictation",
      systemImageName: "doc.on.doc"
    )
  }
}
