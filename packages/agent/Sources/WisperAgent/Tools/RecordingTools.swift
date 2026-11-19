import Foundation
import WisperDomain

// Recording happens in the Open Wisper app, not here. These tools ask the
// running app to start or stop through its `openwisper://` links, then watch
// the library until the app has done it.

extension Catalogue {
  static let recording: [Tool] = [
    Tool(
      path: ["recording", "status"],
      title: "Recording status",
      summary: "Say whether a meeting is being recorded right now.",
      description:
        "Says whether Open Wisper is recording a meeting right now, and if so which one and for how "
        + "long. It also lists meetings whose notes are still being written, and whether the app seems to "
        + "be running. Call it before recording_start or recording_stop when you are not sure of the state.",
      hints: .reads,
      example: "wisper recording status",
      run: { box, _ in try await box.recordingStatus() }
    ),
    Tool(
      path: ["recording", "start"],
      title: "Start recording a meeting",
      summary: "Ask the Open Wisper app to start recording a meeting.",
      description:
        "Asks the running Open Wisper app to start recording a meeting (the microphone, and the "
        + "computer's sound when that is turned on). It waits a few seconds and returns the new meeting's "
        + "ID once the app has started. If a meeting is already being recorded it returns that one and "
        + "starts nothing. Recording captures audio of the people in the room or on the call, so only "
        + "call it when the user has asked for a recording.",
      params: [.text("title", "A title for the meeting. Left out, the app names it.")],
      hints: .sets,
      example: "wisper recording start --title \"Design review\"",
      run: { box, arguments in try await box.startRecording(arguments) }
    ),
    Tool(
      path: ["recording", "stop"],
      title: "Stop recording",
      summary: "Ask the Open Wisper app to stop the recording.",
      description:
        "Asks the running Open Wisper app to stop the meeting recording. It waits a few seconds and "
        + "returns the meeting. The app then writes the transcript and notes, which can take a minute: "
        + "the meeting's status is \"processing\" until it becomes \"ready\". Call meetings_get later to "
        + "read the notes. If nothing is being recorded it says so and does nothing.",
      hints: .sets,
      example: "wisper recording stop",
      run: { box, _ in try await box.stopRecording() }
    ),
  ]
}

extension Toolbox {
  private func liveMeeting() async throws -> Meeting? {
    try await library.meetings().first { $0.status == .recording }
  }

  private func live(_ meeting: Meeting) -> JSONObject {
    [
      "id": .string(meeting.id.uuidString),
      "title": .string(meeting.title),
      "started_at": .string(iso(meeting.startedAt)),
      "elapsed_seconds": .int(max(0, Int(now.timeIntervalSince(meeting.startedAt)))),
      "status": .string(meeting.status.rawValue),
    ]
  }

  /// Asks the library again and again until `find` returns something or the app has had long enough.
  private func wait<Found: Sendable>(for find: () async throws -> Found?) async throws -> Found? {
    let deadline = ContinuousClock.now + environment.appWait
    while true {
      if let found = try await find() { return found }
      guard ContinuousClock.now < deadline else { return nil }
      try await Task.sleep(for: .milliseconds(150))
    }
  }

  private func send(_ link: WisperLink) async throws {
    do {
      try await environment.openLink(link.url)
    } catch let error as AgentError {
      throw error
    } catch {
      throw AgentError.failed("Could not reach the Open Wisper app: \(error.localizedDescription)")
    }
  }

  /// What to tell the caller when the app did not act on a link in time.
  private func noAnswer(_ what: String) async -> AgentError {
    let seconds = Int(environment.appWait.components.seconds)
    let hint =
      switch await environment.appIsRunning() {
      case false?: "The Open Wisper app does not seem to be running. Open it, then try again."
      case true?:
        "The app is running, so look at its window: it may be asking for microphone access or an API key."
      case nil: "Check that the Open Wisper app is open."
      }
    return .failed(
      "Open Wisper did not \(what) within \(seconds) seconds. \(hint) It may still do it a little later, so "
        + "check the recording status before trying again."
    )
  }

  fileprivate func recordingStatus() async throws -> ToolOutput {
    let meetings = try await library.meetings()
    let recording = meetings.first { $0.status == .recording }
    let processing = meetings.filter { $0.status == .processing }
    let running = await environment.appIsRunning()
    var data: JSONObject = ["recording": .bool(recording != nil)]
    var lines: [String] = []
    if let recording {
      data["meeting"] = .object(live(recording))
      let minutes = max(0, Int(now.timeIntervalSince(recording.startedAt))) / 60
      lines.append("Recording \"\(recording.title)\" for \(minutes) min (\(recording.id.uuidString)).")
      if running == false {
        data["warning"] = "The app is not running, so this recording has probably stopped."
        lines.append("The app is not running, so this recording has probably stopped.")
      }
    } else {
      lines.append("Not recording.")
    }
    if !processing.isEmpty {
      data["processing"] = .array(processing.map { .object(live($0)) })
      lines.append(
        "Notes are being written for: " + processing.map { "\"\($0.title)\"" }.joined(separator: ", ")
      )
    }
    if let running {
      data["app_running"] = .bool(running)
      lines.append(running ? "The Open Wisper app is running." : "The Open Wisper app is not running.")
    }
    return ToolOutput(data: data, text: lines.joined(separator: "\n"))
  }

  fileprivate func startRecording(_ arguments: Arguments) async throws -> ToolOutput {
    if let already = try await liveMeeting() {
      return ToolOutput(
        data: ["started": false, "already_recording": true, "meeting": .object(live(already))],
        text: "Already recording \"\(already.title)\" (\(already.id.uuidString)). Nothing new was started."
      )
    }
    let title = arguments.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines)
    try await send(.startMeeting(title: title))
    guard let meeting = try await wait(for: liveMeeting) else {
      throw await noAnswer("start recording")
    }
    return ToolOutput(
      data: ["started": true, "meeting": .object(live(meeting))],
      text: "Recording \"\(meeting.title)\" (\(meeting.id.uuidString))."
    )
  }

  fileprivate func stopRecording() async throws -> ToolOutput {
    guard let recording = try await liveMeeting() else {
      return ToolOutput(data: ["stopped": false, "recording": false], text: "Nothing is being recorded.")
    }
    try await send(.stopMeeting)
    let stopped = try await wait {
      let meeting = try await library.meeting(recording.id)
      return meeting?.status == .recording ? nil : (meeting ?? recording)
    }
    guard let stopped else { throw await noAnswer("stop recording") }
    let exists = try await library.meeting(recording.id) != nil
    guard exists else {
      return ToolOutput(
        data: ["stopped": true, "kept": false, "meeting_id": .string(recording.id.uuidString)],
        text: "Stopped. The app did not keep \"\(recording.title)\" (it may have been too short)."
      )
    }
    var text = "Stopped recording \"\(stopped.title)\" (\(stopped.id.uuidString))."
    if stopped.status == .processing {
      text += "\nThe transcript and notes are being written. This can take a minute."
    }
    return ToolOutput(data: ["stopped": true, "meeting": .object(summary(of: stopped))], text: text)
  }
}
