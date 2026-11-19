import Foundation
import WisperDomain

// Recording happens in the Open Wisper app, not here. These tools ask the
// running app to start or stop through its `openwisper://` links, then watch
// the library until the app has done it.
//
// Anything can open such a link: a web page, a document, a message. So the
// app acts without asking only on a link that carries a ticket, a one-time
// token this tool leaves in the data folder. Being able to write there is the
// proof that the request comes from the user's own tool.

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
      params: [
        .text(
          "title",
          "A title for the meeting: one line, at most \(Limits.linkTitle) characters. Left out, the app "
            + "names it.",
          limit: Limits.linkTitle
        )
      ],
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
        + "read the notes. If nothing is being recorded it says so and does nothing. Stopping ends the "
        + "recording for good, so only call it when the user has asked for the recording to stop.",
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
      "elapsed_seconds": .int(Toolbox.whole(now.timeIntervalSince(meeting.startedAt))),
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

  /// Hands a link to the app. A link that makes the app listen, or cuts a recording short,
  /// goes with a fresh ticket from the data folder the library uses, so the app knows it
  /// comes from this tool and acts without asking the user.
  ///
  /// Returns whether a ticket went with the link. When the data folder cannot be written
  /// (a tool started with read-only access, say) there is none: the link is sent bare, and
  /// it is then up to the app and the user whether anything happens.
  private func send(_ link: WisperLink) async throws -> Bool {
    let folder = environment.dataFolder
    let ticket = link.needsTrust ? try? LinkTicket.issue(in: folder) : nil
    do {
      try await environment.openLink(link.url(ticket: ticket))
    } catch {
      // The link went nowhere, so its ticket is used up here instead of being left behind.
      if let ticket { _ = LinkTicket.redeem(ticket, in: folder) }
      if let error = error as? AgentError { throw error }
      throw AgentError.failed("Could not reach the Open Wisper app: \(error.localizedDescription)")
    }
    return ticket != nil || !link.needsTrust
  }

  /// What to tell the caller when the app did not act on a link in time.
  private func noAnswer(_ what: String, trusted: Bool) async -> AgentError {
    let seconds = Int(environment.appWait.components.seconds)
    let hint: String
    if !trusted {
      hint =
        "This tool could not write to the data folder at \(environment.dataFolder.path), so the app "
        + "cannot tell that the request came from it. The app then asks the user before it starts a "
        + "recording, and does not stop one: use the app's own button."
    } else {
      hint =
        switch await environment.appIsRunning() {
        case false?: "The Open Wisper app does not seem to be running. Open it, then try again."
        case true?:
          "The app is running, so look at its window: it may be asking for microphone access or an API "
            + "key."
        case nil: "Check that the Open Wisper app is open."
        }
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
      let minutes = Toolbox.whole(now.timeIntervalSince(recording.startedAt)) / 60
      lines.append("Recording \"\(recording.name)\" for \(minutes) min (\(recording.id.uuidString)).")
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
        "Notes are being written for: " + processing.map { "\"\($0.name)\"" }.joined(separator: ", ")
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
        text: "Already recording \"\(already.name)\" (\(already.id.uuidString)). Nothing new was started."
      )
    }
    // The title becomes the heading of the meeting's notes, so it is one clean line.
    let title = arguments.string("title").map(Toolbox.oneLine)
    let trusted = try await send(.startMeeting(title: (title?.isEmpty ?? true) ? nil : title))
    guard let meeting = try await wait(for: liveMeeting) else {
      throw await noAnswer("start recording", trusted: trusted)
    }
    return ToolOutput(
      data: ["started": true, "meeting": .object(live(meeting))],
      text: "Recording \"\(meeting.name)\" (\(meeting.id.uuidString))."
    )
  }

  fileprivate func stopRecording() async throws -> ToolOutput {
    guard let recording = try await liveMeeting() else {
      return ToolOutput(data: ["stopped": false, "recording": false], text: "Nothing is being recorded.")
    }
    let trusted = try await send(.stopMeeting)
    let stopped = try await wait {
      let meeting = try await library.meeting(recording.id)
      return meeting?.status == .recording ? nil : (meeting ?? recording)
    }
    guard let stopped else { throw await noAnswer("stop recording", trusted: trusted) }
    let exists = try await library.meeting(recording.id) != nil
    guard exists else {
      return ToolOutput(
        data: ["stopped": true, "kept": false, "meeting_id": .string(recording.id.uuidString)],
        text: "Stopped. The app did not keep \"\(recording.name)\" (it may have been too short)."
      )
    }
    var text = "Stopped recording \"\(stopped.name)\" (\(stopped.id.uuidString))."
    if stopped.status == .processing {
      text += "\nThe transcript and notes are being written. This can take a minute."
    }
    return ToolOutput(data: ["stopped": true, "meeting": .object(summary(of: stopped))], text: text)
  }
}
