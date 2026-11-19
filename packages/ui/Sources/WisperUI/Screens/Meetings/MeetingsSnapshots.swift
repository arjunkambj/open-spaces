import SwiftUI
import WisperDomain
import WisperEngine

/// Snapshot cases for this area. See `SnapshotCase`.
enum MeetingsSnapshots {
  @MainActor static var cases: [SnapshotCase] {
    list + detail
  }

  @MainActor private static var list: [SnapshotCase] {
    [
      SnapshotCase("meetings", model: { model() }) { screen() },
      SnapshotCase("meetings-phone", canvas: .phone, model: { model() }) { screen() },
      SnapshotCase("meetings-list", model: { model(MeetingSamples.many) }) {
        screen(preset: MeetingsPreset())
      },
      SnapshotCase("meetings-list-phone", canvas: .phone, model: { model(MeetingSamples.many) }) {
        screen(preset: MeetingsPreset())
      },
      SnapshotCase("meetings-empty", model: { model([]) }) { screen() },
      SnapshotCase("meetings-empty-phone", canvas: .phone, model: { model([]) }) { screen() },
      SnapshotCase("meetings-live", model: { recording() }) { screen() },
      SnapshotCase("meetings-live-phone", canvas: .phone, model: { recording() }) { screen() },
      SnapshotCase("meetings-live-quiet", model: { recording(heard: false) }) { screen() },
      // The Mac could not record what it plays: the engine says so while the meeting goes on.
      SnapshotCase("meetings-live-microphone-only", model: { recording(microphoneOnly: true) }) { screen() },
      SnapshotCase(
        "meetings-live-microphone-only-phone",
        canvas: .phone,
        model: { recording(microphoneOnly: true) }
      ) { screen() },
      SnapshotCase("meetings-search", model: { model(MeetingSamples.many) }) {
        screen(preset: MeetingsPreset(query: "billing"))
      },
      SnapshotCase("meetings-search-none", model: { model(MeetingSamples.many) }) {
        screen(preset: MeetingsPreset(query: "zebra"))
      },
      SnapshotCase("meetings-delete", model: { model() }) {
        screen(preset: MeetingsPreset(confirmsDelete: true))
      },
      SnapshotCase("meetings-delete-phone", canvas: .phone, model: { model() }) {
        screen(preset: MeetingsPreset(confirmsDelete: true))
      },
      SnapshotCase("meetings-no-microphone", model: { model(hasAPIKey: false, microphone: .denied) }) {
        screen(
          preset: MeetingsPreset(startFailure: .permissionDenied(.microphone))
        )
      },
      SnapshotCase("meetings-no-microphone-phone", canvas: .phone, model: { model(microphone: .denied) }) {
        screen(
          preset: MeetingsPreset(startFailure: .permissionDenied(.microphone))
        )
      },
    ]
  }

  @MainActor private static var detail: [SnapshotCase] {
    let sync = MeetingSamples.syncID
    return [
      SnapshotCase("meeting-notes", model: { model() }) { screen(sync) },
      SnapshotCase("meeting-notes-phone", canvas: .phone, model: { model() }) { screen(sync) },
      // Tall, so the whole Notes tab shows: the checklist and the questions under it.
      SnapshotCase("meeting-asked", canvas: .custom(width: 880, height: 1_500), model: { model() }) {
        screen(sync, preset: MeetingsPreset(questions: MeetingSamples.questions))
          .background(Wisper.Color.panel)
      },
      SnapshotCase("meeting-checklist-phone", canvas: .phone, model: { model(MeetingSamples.checklist) }) {
        screen(MeetingSamples.checklistID, preset: MeetingsPreset(questions: MeetingSamples.questions))
      },
      SnapshotCase("meeting-transcript", model: { model() }) {
        screen(sync, preset: MeetingsPreset(tab: .transcript))
      },
      SnapshotCase("meeting-transcript-find", model: { model() }) {
        screen(sync, preset: MeetingsPreset(tab: .transcript, find: "billing"))
      },
      SnapshotCase("meeting-transcript-find-phone", canvas: .phone, model: { model() }) {
        screen(sync, preset: MeetingsPreset(tab: .transcript, find: "billing"))
      },
      SnapshotCase("meeting-my-notes", model: { model() }) {
        screen(sync, preset: MeetingsPreset(tab: .myNotes))
      },
      SnapshotCase("meeting-my-notes-phone", canvas: .phone, model: { model() }) {
        screen(sync, preset: MeetingsPreset(tab: .myNotes))
      },
      SnapshotCase("meeting-tags", model: { model() }) {
        screen(sync, preset: MeetingsPreset(editsTags: true))
      },
      SnapshotCase("meeting-delete", model: { model() }) {
        screen(sync, preset: MeetingsPreset(confirmsDelete: true))
      },
      SnapshotCase("meeting-long", model: { model(MeetingSamples.many) }) {
        screen(MeetingSamples.longID)
      },
      SnapshotCase("meeting-long-phone", canvas: .phone, model: { model(MeetingSamples.many) }) {
        screen(MeetingSamples.longID)
      },
      SnapshotCase("meeting-processing", model: { model(MeetingSamples.many) }) {
        screen(MeetingSamples.processingID)
      },
      SnapshotCase("meeting-processing-phone", canvas: .phone, model: { model(MeetingSamples.many) }) {
        screen(MeetingSamples.processingID)
      },
      SnapshotCase("meeting-failed", model: { model(MeetingSamples.many) }) {
        screen(MeetingSamples.failedID)
      },
      SnapshotCase("meeting-failed-phone", canvas: .phone, model: { model(MeetingSamples.many) }) {
        screen(MeetingSamples.failedID)
      },
      SnapshotCase("meeting-part-missing", model: { model(MeetingSamples.many) }) {
        screen(MeetingSamples.partID, preset: MeetingsPreset(tab: .transcript))
      },
      // What was lost is gone for good: the notice has no button.
      SnapshotCase("meeting-part-lost", model: { model(MeetingSamples.many) }) {
        screen(MeetingSamples.lostID)
      },
      SnapshotCase("meeting-part-lost-phone", canvas: .phone, model: { model(MeetingSamples.many) }) {
        screen(MeetingSamples.lostID)
      },
      SnapshotCase("meeting-no-notes", model: { model(MeetingSamples.many) }) {
        screen(MeetingSamples.noNotesID)
      },
      SnapshotCase("meeting-gone", model: { model() }) { screen(UUID()) },
      SnapshotCase("meeting-live", model: { recording() }) { MeetingLiveSnapshot(tab: .transcript) },
      SnapshotCase("meeting-live-phone", canvas: .phone, model: { recording() }) {
        MeetingLiveSnapshot(tab: .transcript)
      },
      SnapshotCase("meeting-live-notes", model: { recording(heard: false) }) {
        MeetingLiveSnapshot(tab: .notes)
      },
    ]
  }

  @MainActor
  private static func screen(
    _ meeting: Meeting.ID? = nil,
    preset: MeetingsPreset = MeetingsPreset()
  ) -> some View {
    MeetingsScreen(selection: .constant(meeting), preset: preset)
  }

  @MainActor
  private static func model(
    _ meetings: [Meeting] = MeetingSamples.few,
    hasAPIKey: Bool = true,
    microphone: PermissionStatus = .granted,
    capture: FakeAudioCapture = FakeAudioCapture(),
    transcriber: FakeTranscriber = FakeTranscriber(text: "")
  ) -> AppModel {
    AppModel(
      .init(
        library: InMemoryLibrary(
          settings: Settings(userName: "Alex", onboardedAt: Date()),
          meetings: meetings
        ),
        secrets: InMemorySecretStore(apiKey: hasAPIKey ? "sk-demo" : nil),
        capture: capture,
        transcriber: transcriber,
        languageModel: FakeLanguageModel(text: ""),
        target: FakeTextTarget(),
        permissions: FakePermissions(statuses: [.microphone: microphone, .systemAudio: .granted]),
        checkAPIKey: { _ in }
      )
    )
  }

  /// A model whose engine is recording, with a few lines already heard.
  @MainActor
  private static func recording(heard: Bool = true, microphoneOnly: Bool = false) -> AppModel {
    let capture = FakeAudioCapture()
    let lines = MeetingSamples.liveLines
    let transcriber = FakeTranscriber { request in
      Transcript(text: lines[request.audio.lastPathComponent] ?? "")
    }
    let model = model(capture: capture, transcriber: transcriber)
    Task {
      _ = try? await model.meetings.start(title: "Pricing review")
      if microphoneOnly {
        // What the engine reports on a Mac whose system sound could not be recorded.
        model.meetings.lastError =
          "Only your microphone is being recorded. "
          + WisperError.permissionDenied(.systemAudio).localizedDescription
      }
      guard heard else { return }
      for _ in 0..<3 { capture.sessions.last?.emit(duration: 30) }
    }
    return model
  }
}

/// Opens the page of the meeting being recorded, whose ID is only known once it has started.
private struct MeetingLiveSnapshot: View {
  let tab: MeetingTab
  @Environment(AppModel.self) private var model

  var body: some View {
    if let id = model.meetings.live?.meetingID {
      MeetingsScreen(selection: .constant(id), preset: MeetingsPreset(tab: tab))
    }
  }
}

// MARK: - Sample meetings (made up)

@MainActor
private enum MeetingSamples {
  static let syncID = id(1)
  static let longID = id(2)
  static let processingID = id(3)
  static let failedID = id(4)
  static let partID = id(5)
  static let noNotesID = id(6)
  static let checklistID = id(7)
  static let lostID = id(8)

  /// A meeting whose notes are only a checklist, with a question that could not be answered.
  static var checklist: [Meeting] {
    let start = ago(hours: 5)
    return [
      Meeting(
        id: checklistID,
        title: "Offsite prep",
        startedAt: start,
        endedAt: start.addingTimeInterval(900),
        status: .ready,
        segments: [TranscriptSegment(speaker: .me, start: 1, end: 6, text: "Let's split the offsite tasks.")],
        notes: MeetingNotes(actionItems: [
          ActionItem(text: "Book the train tickets for everyone coming from out of town", owner: "Jordan"),
          ActionItem(text: "Order lunch", done: true),
        ])
      )
    ]
  }

  private static func id(_ number: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-00000000000\(number)") ?? UUID()
  }

  private static func ago(hours: Double) -> Date {
    Date().addingTimeInterval(-hours * 3_600)
  }

  /// What the fake transcriber "hears" in each chunk of the live recording.
  static let liveLines = [
    "microphone-0.m4a": "Thanks for making time. I want to settle the price of the team plan today.",
    "system-0.m4a":
      "Sure. Most teams we talked to said twelve a seat felt fair, as long as there is a free tier.",
    "microphone-1.m4a": "Twelve works for me. Should the free tier have a limit on meetings?",
    "system-1.m4a": "I would cap it at five meetings a month and see how people use it.",
    "microphone-2.m4a": "Good. Let's write that down and check it again after the first month.",
  ]

  static var questions: MeetingQuestions {
    MeetingQuestions(threads: [
      syncID: [
        .init(
          question: "What was decided?",
          reply: .answer(
            "The launch stays on the 14th. Sam's team moves the billing data over the weekend before, "
              + "and the old checkout stays on for one more week as a fallback."
          )
        ),
        .init(question: "Who owns the onboarding copy?", reply: .waiting),
      ],
      checklistID: [
        .init(
          question: "Who books the venue?",
          reply: .failed("Could not reach OpenAI. Check your internet connection. (The request timed out.)")
        )
      ],
    ])
  }

  static var sync: Meeting {
    let start = ago(hours: 26)
    let lines: [(Speaker, TimeInterval, String)] = [
      (.me, 2, "Thanks for joining. Let's start with the launch date."),
      (.others, 10, "We're on track for the 14th. The only open risk is the billing migration."),
      (.others, 24, "Sam's team wants to move the billing data over the weekend before, so support is free."),
      (.me, 41, "Okay. I'll check in with Sam about billing today."),
      (.others, 52, "I can have the onboarding copy ready by Wednesday so design can review it."),
      (.me, 66, "Great. Is there anything else that could move the date?"),
      (.others, 75, "Only if the billing move slips. We keep the old checkout on for a week as a fallback."),
      (.me, 190, "Then we keep the 14th. I'll send the notes around after this."),
    ]
    return Meeting(
      id: syncID,
      title: "Weekly product sync",
      startedAt: start,
      endedAt: start.addingTimeInterval(1_860),
      status: .ready,
      segments: lines.map { TranscriptSegment(speaker: $0.0, start: $0.1, end: $0.1 + 8, text: $0.2) },
      notes: MeetingNotes(
        summary:
          "The team confirmed the launch is on track for the 14th. The billing migration is the one open "
          + "risk; the old checkout stays on for a week as a fallback. Onboarding copy will be ready for "
          + "design review mid-week.",
        keyPoints: [
          "Launch stays on the 14th.",
          "The billing migration is the main risk and happens the weekend before.",
          "Onboarding copy is due on Wednesday.",
        ],
        decisions: ["Keep the launch date.", "Leave the old checkout on for one more week."],
        actionItems: [
          ActionItem(text: "Check in with Sam about the billing migration", owner: "Alex"),
          ActionItem(text: "Send onboarding copy to design", owner: "Jordan", done: true),
          ActionItem(text: "Share the notes with the team"),
        ]
      ),
      userNotes:
        "Follow up on the pricing page next week.\n\n- Ask Priya for the new screenshots\n- Book the launch retro",
      tags: ["product", "launch"]
    )
  }

  static var few: [Meeting] {
    let call = ago(hours: 3 * 24 + 2)
    let chat = ago(hours: 6 * 24)
    return [
      sync,
      Meeting(
        title: "Customer call with Northwind",
        startedAt: call,
        endedAt: call.addingTimeInterval(2_700),
        status: .ready,
        segments: [
          TranscriptSegment(
            speaker: .others,
            start: 4,
            end: 15,
            text: "Our team mostly dictates notes after site visits."
          )
        ],
        notes: MeetingNotes(
          summary: "Northwind's field team dictates notes after site visits and shares them by email.",
          actionItems: [ActionItem(text: "Send a summary and pricing", owner: "Alex")]
        ),
        tags: ["customer"]
      ),
      Meeting(
        title: "1:1 with Jordan",
        startedAt: chat,
        endedAt: chat.addingTimeInterval(1_500),
        status: .ready,
        segments: [TranscriptSegment(speaker: .me, start: 1, end: 6, text: "How is the week going?")]
      ),
    ]
  }

  /// Every state a meeting can be in, and one with far too much of everything.
  static var many: [Meeting] {
    let talk = TranscriptSegment(speaker: .me, start: 3, end: 12, text: "Let's get started.")
    let today = ago(hours: 0.4)
    let earlier = ago(hours: 2)
    let partStart = ago(hours: 30)
    let lostStart = ago(hours: 3 * 24)
    let longStart = ago(hours: 5 * 24)
    let noNotesStart = ago(hours: 40 * 24)
    let old = ago(hours: 400 * 24)
    let speakers: [Speaker] = [.me, .others, .named("Priya Raman")]
    let filler: String =
      "This is a long stretch of talk about plans for the quarter, with enough words to wrap over "
      + "several lines so the transcript can be checked at every width."
    let longTalk: [TranscriptSegment] = (0..<60).map { index in
      let start = TimeInterval(index * 40)
      return TranscriptSegment(speaker: speakers[index % 3], start: start, end: start + 30, text: filler)
    }
    let longSummary: String =
      "The three teams walked through their goals for the quarter and agreed on what comes first. "
      + "Platform keeps the storage rewrite as its main project and expects it to take until the "
      + "middle of the quarter. Growth wants to double the number of people who finish setting "
      + "up, and asked for one more engineer to do it. Support is short of people on weekends."
    let longPoints: [String] = (1...6).map { number in
      "Point \(number): each team named the one thing it cannot drop this quarter."
    }
    let longTask: String =
      "Write up the budget request for the two new roles and send it to finance before the end "
      + "of the month so it can be reviewed in time"
    let processing = Meeting(
      id: processingID,
      title: "Design review",
      startedAt: today,
      endedAt: today.addingTimeInterval(1_260),
      status: .processing,
      segments: [talk]
    )
    let failed = Meeting(
      id: failedID,
      title: "Meeting, 19 Nov, 9:02 AM",
      startedAt: earlier,
      endedAt: earlier.addingTimeInterval(2_040),
      status: .failed,
      failure: "This meeting could not be transcribed. Could not reach OpenAI. "
        + "Check your internet connection. (The request timed out.)"
    )
    let part = Meeting(
      id: partID,
      title: "Hiring sync",
      startedAt: partStart,
      endedAt: partStart.addingTimeInterval(3_300),
      status: .ready,
      failure: "Part of this meeting could not be transcribed. OpenAI is limiting requests for your key "
        + "right now. Try again in a moment.",
      segments: [
        talk,
        TranscriptSegment(
          speaker: .others,
          start: 14,
          end: 30,
          text: "We have four people in the last round for the design role."
        ),
      ],
      notes: MeetingNotes(summary: "Four candidates are in the last round for the design role."),
      tags: ["hiring"]
    )
    let lost = Meeting(
      id: lostID,
      title: "Call with Dana",
      startedAt: lostStart,
      endedAt: lostStart.addingTimeInterval(1_140),
      status: .ready,
      failure: "The app closed while this meeting was being recorded. The last part could not be saved.",
      segments: [
        talk,
        TranscriptSegment(
          speaker: .others,
          start: 15,
          end: 28,
          text: "The contract is ready. We only need the new start date."
        ),
      ],
      notes: MeetingNotes(summary: "The contract is ready apart from the start date."),
      tags: ["legal"]
    )
    let long = Meeting(
      id: longID,
      title: "Quarterly planning with the platform, growth and support teams: goals, budget and hiring",
      startedAt: longStart,
      endedAt: longStart.addingTimeInterval(6_900),
      status: .ready,
      segments: longTalk,
      notes: MeetingNotes(
        summary: longSummary,
        keyPoints: longPoints,
        decisions: ["Platform finishes the storage rewrite before anything new starts."],
        actionItems: [
          ActionItem(text: longTask, owner: "Priya Raman"),
          ActionItem(text: "Book the follow-up", owner: "Alex", done: true),
        ]
      ),
      tags: ["planning", "platform", "growth", "support", "budget"]
    )
    let noNotes = Meeting(
      id: noNotesID,
      title: "Lunch with the Lisbon team",
      startedAt: noNotesStart,
      endedAt: noNotesStart.addingTimeInterval(40),
      status: .ready,
      segments: [talk]
    )
    let kickoff = Meeting(
      title: "Kickoff",
      startedAt: old,
      endedAt: old.addingTimeInterval(3_600),
      status: .ready,
      failure: "The notes could not be written. OpenAI did not accept your API key. Check it in Settings.",
      segments: [talk]
    )
    return [processing, failed, sync, part, lost, long, noNotes, kickoff]
  }
}
