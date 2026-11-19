import Foundation
import Testing
import WisperDomain

@testable import WisperEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MeetingNotesTests {
  /// Records one short meeting with both sides talking and waits until it is finished.
  private func record(_ rig: MeetingRig, title: String? = nil) async throws -> Meeting {
    let id = try await rig.engine.start(title: title)
    await rig.engine.stop()
    return try await rig.finished(id)
  }

  private static let talk = MeetingRig.hears([
    "microphone-0": "Let's ship on Friday. I will check with Sam about billing.",
    "system-0": "Friday works. Jordan will send the onboarding copy.",
  ])

  // MARK: Writing notes

  @Test func writesNotesFromTheTranscript() async throws {
    let rig = MeetingRig(
      transcriber: MeetingNotesTests.talk,
      model: FakeLanguageModel(
        text: MeetingRig.notesJSON(
          title: " \"Launch planning.\" ",
          summary: "  The team agreed to ship on Friday. ",
          keyPoints: ["Launch is on track", "  "],
          decisions: ["Ship on Friday"],
          actionItems: [
            ("Check with Sam about billing", "Alex"), ("Send the onboarding copy", "Jordan"),
            ("Book a room", nil), ("  ", "Nobody"),
          ]
        )
      )
    )
    let meeting = try await record(rig)

    #expect(meeting.title == "Launch planning")
    let notes = try #require(meeting.notes)
    #expect(notes.summary == "The team agreed to ship on Friday.")
    #expect(notes.keyPoints == ["Launch is on track"])
    #expect(notes.decisions == ["Ship on Friday"])
    #expect(
      notes.actionItems.map(\.text) == [
        "Check with Sam about billing", "Send the onboarding copy", "Book a room",
      ]
    )
    #expect(notes.actionItems.map(\.owner) == ["Alex", "Jordan", nil])
    #expect(notes.actionItems.allSatisfy { !$0.done })

    // One request, with a strict reply format, the user's model and name, and the transcript.
    #expect(rig.model.requests.count == 1)
    let request = try #require(rig.model.requests.first)
    #expect(request.model == Settings.defaultTextModel)
    #expect(request.system.contains("\"Me\" is Alex"))
    #expect(request.user.contains("[00:00] Me: Let's ship on Friday. I will check with Sam about billing."))
    #expect(request.user.contains("[00:00] Others: Friday works. Jordan will send the onboarding copy."))
    let schema = try #require(request.jsonSchema)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
    #expect(object["additionalProperties"] as? Bool == false)
    #expect(
      Set(object["required"] as? [String] ?? [])
        == ["title", "summary", "keyPoints", "decisions", "actionItems"]
    )
  }

  @Test func keepsATitleTheUserChose() async throws {
    let rig = MeetingRig(transcriber: MeetingNotesTests.talk)
    let meeting = try await record(rig, title: "Standup")
    #expect(meeting.title == "Standup")
    #expect(meeting.notes != nil)
  }

  @Test func editsMadeWhileProcessingSurvive() async throws {
    let reachedNotes = MeetingGate()
    let releaseNotes = MeetingGate()
    let rig = MeetingRig(
      transcriber: MeetingNotesTests.talk,
      model: FakeLanguageModel { _ in
        reachedNotes.open()
        await releaseNotes.wait()
        return MeetingRig.notesJSON()
      }
    )
    let id = try await rig.engine.start()
    await rig.engine.stop()
    await reachedNotes.wait()

    // The user (or an agent) edits the meeting while the notes are being written.
    var edited = try await rig.meeting(id)
    #expect(edited.status == .processing)
    edited.title = "Budget review"
    edited.userNotes = "Ask about the Q3 numbers."
    edited.tags = ["finance"]
    await rig.library.save(edited)

    releaseNotes.open()
    let meeting = try await rig.finished(id)
    #expect(meeting.status == .ready)
    #expect(meeting.title == "Budget review")
    #expect(meeting.userNotes == "Ask about the Q3 numbers.")
    #expect(meeting.tags == ["finance"])
    #expect(meeting.notes?.summary == "The team talked about the launch.")
    #expect(meeting.segments.count == 2)
  }

  @Test func leavesTheNotesAloneWhenAutoSummarizeIsOff() async throws {
    let rig = MeetingRig(
      settings: Settings(meetings: MeetingSettings(autoSummarize: false)),
      transcriber: MeetingNotesTests.talk
    )
    let meeting = try await record(rig)
    #expect(meeting.status == .ready)
    #expect(meeting.notes == nil)
    #expect(meeting.title == MeetingEngine.placeholderTitle(for: meeting.startedAt))
    #expect(meeting.segments.count == 2)
    #expect(rig.model.requests.isEmpty)

    // Notes can still be asked for by hand, and then the title comes too.
    try await rig.engine.regenerateNotes(meeting.id)
    let withNotes = try await rig.meeting(meeting.id)
    #expect(withNotes.notes?.decisions == ["Ship on Friday"])
    #expect(withNotes.title == "Launch planning")
    #expect(rig.engine.processing.isEmpty)
  }

  @Test func deletesTheAudioOnceTheMeetingIsReady() async throws {
    let rig = MeetingRig(
      settings: Settings(meetings: MeetingSettings(keepAudio: false)),
      transcriber: MeetingNotesTests.talk
    )
    let meeting = try await record(rig)
    #expect(meeting.status == .ready)
    #expect(meeting.segments.count == 2)
    #expect(try await rig.audioFiles(meeting.id).isEmpty)
  }

  @Test func aFailedNotesRequestKeepsTheTranscript() async throws {
    let down = MeetingSwitch(true)
    let rig = MeetingRig(
      settings: Settings(meetings: MeetingSettings(keepAudio: false)),
      transcriber: MeetingNotesTests.talk,
      model: FakeLanguageModel { _ in
        if down.isOn { throw WisperError.rateLimited }
        return MeetingRig.notesJSON()
      }
    )
    let meeting = try await record(rig)
    #expect(meeting.status == .ready)
    #expect(meeting.segments.count == 2)
    #expect(meeting.notes == nil)
    #expect(
      meeting.failure == "The notes could not be written. " + WisperError.rateLimited.localizedDescription
    )
    await #expect(throws: WisperError.rateLimited) { try await rig.engine.regenerateNotes(meeting.id) }

    down.set(false)
    try await rig.engine.regenerateNotes(meeting.id)
    let fixed = try await rig.meeting(meeting.id)
    #expect(fixed.notes != nil)
    #expect(fixed.failure == nil)
    #expect(fixed.title == "Launch planning")
  }

  @Test func aReplyThatIsNotNotesIsAnError() async throws {
    let rig = MeetingRig(
      transcriber: MeetingNotesTests.talk,
      model: FakeLanguageModel(text: "Sure! Here you go.")
    )
    let meeting = try await record(rig)
    #expect(meeting.status == .ready)
    #expect(meeting.notes == nil)
    #expect(meeting.failure?.hasPrefix("The notes could not be written.") == true)
  }

  // MARK: Regenerating

  @Test func regeneratingKeepsTickedActionItems() async throws {
    let second = MeetingSwitch(false)
    let rig = MeetingRig(
      transcriber: MeetingNotesTests.talk,
      model: FakeLanguageModel { _ in
        guard second.isOn else { return MeetingRig.notesJSON() }
        return MeetingRig.notesJSON(
          title: "A different title",
          summary: "A fresh summary.",
          actionItems: [("Send the onboarding copy", "Jordan"), ("check with Sam about billing.", "Alex")]
        )
      }
    )
    var meeting = try await record(rig)
    let item = try #require(meeting.notes?.actionItems.first)
    #expect(item.text == "Check with Sam about billing")
    meeting.notes?.actionItems[0].done = true
    await rig.library.save(meeting)

    second.set(true)
    try await rig.engine.regenerateNotes(meeting.id)
    let notes = try #require(try await rig.meeting(meeting.id).notes)
    #expect(notes.summary == "A fresh summary.")
    #expect(notes.actionItems.map(\.text) == ["Send the onboarding copy", "check with Sam about billing."])
    #expect(notes.actionItems.map(\.done) == [false, true])
    #expect(notes.actionItems[1].id == item.id)
    // The first generated title stays: only the dated placeholder is ever replaced.
    #expect(try await rig.meeting(meeting.id).title == "Launch planning")
    #expect(rig.model.requests.count == 2)
  }

  @Test func regeneratingNeedsATranscript() async throws {
    let empty = Meeting(title: "Quiet", status: .ready)
    let rig = MeetingRig(library: InMemoryLibrary(meetings: [empty]))
    await #expect(throws: WisperError.noSpeech) { try await rig.engine.regenerateNotes(empty.id) }
    await #expect(throws: WisperError.notFound("The meeting")) {
      try await rig.engine.regenerateNotes(UUID())
    }
    #expect(rig.model.requests.isEmpty)
    #expect(rig.engine.processing.isEmpty)
  }

  // MARK: Long meetings

  @Test func summarisesALongMeetingInPartsAndCombinesThem() async throws {
    let segments = (0..<12).map { index in
      TranscriptSegment(
        speaker: index.isMultiple(of: 2) ? .me : .others,
        start: Double(index) * 30,
        end: Double(index) * 30 + 30,
        text: "Point number \(index) was talked through in detail."
      )
    }
    let long = Meeting(title: "All hands", status: .ready, segments: segments)
    let model = FakeLanguageModel { request in
      if request.user.hasPrefix("This is part") {
        let covered = segments.filter { request.user.contains($0.text) }.map(\.text)
        return MeetingRig.notesJSON(
          title: "Part",
          summary: "Part summary.",
          keyPoints: covered,
          decisions: []
        )
      }
      return MeetingRig.notesJSON(title: "Whole meeting", summary: "Everything, combined.")
    }
    // Each transcript line is about 65 characters, so every request can hold two of them.
    let rig = MeetingRig(
      library: InMemoryLibrary(meetings: [long]),
      model: model,
      tuning: MeetingRig.tuning(notesCharacterLimit: 140)
    )
    try await rig.engine.regenerateNotes(long.id)

    let requests = rig.model.requests
    let parts = requests.filter { $0.user.hasPrefix("This is part") }
    #expect(parts.count == 6)
    #expect(parts.allSatisfy { $0.user.contains("of 6 of a long meeting") })
    // Every line of the transcript went into exactly one part.
    for segment in segments {
      #expect(parts.filter { $0.user.contains(segment.text) }.count == 1)
    }
    // No request was longer than allowed.
    #expect(parts.allSatisfy { $0.user.count < 140 + 120 })
    // The parts were combined, in more than one round because their notes do not fit in one.
    let merges = requests.filter { !$0.user.hasPrefix("This is part") }
    #expect(merges.count > 1)
    #expect(
      merges.allSatisfy { $0.user.contains("Part summary.") || $0.user.contains("Everything, combined.") }
    )
    #expect(requests.allSatisfy { $0.jsonSchema != nil })

    let meeting = try await rig.meeting(long.id)
    #expect(meeting.notes?.summary == "Everything, combined.")
    // "All hands" was chosen by the user.
    #expect(meeting.title == "All hands")
  }

  // MARK: Questions

  @Test func answersAQuestionFromTheMeeting() async throws {
    let meeting = try #require(SampleData.meetings().first)
    let rig = MeetingRig(
      library: InMemoryLibrary(settings: Settings(userName: "Alex"), meetings: [meeting]),
      model: FakeLanguageModel(text: "The launch is planned for the 14th.")
    )
    let answer = try await rig.engine.ask("  When is the launch? ", about: meeting.id)
    #expect(answer == "The launch is planned for the 14th.")

    let request = try #require(rig.model.requests.first)
    #expect(rig.model.requests.count == 1)
    #expect(request.jsonSchema == nil)
    #expect(request.system.contains("did not come up in this meeting"))
    #expect(request.system.contains("\"Me\" is Alex"))
    #expect(request.user.contains("Question: When is the launch?"))
    #expect(request.user.contains("We're on track for the 14th."))
    #expect(request.user.contains("Keep the launch date"))
    #expect(request.user.contains("Send onboarding copy to design (done) (owner: Jordan)"))
    #expect(request.user.contains("Follow up on pricing page next week."))
    // Asking changes nothing.
    #expect(try await rig.meeting(meeting.id) == meeting)
  }

  @Test func answersFromALongMeetingInTwoSteps() async throws {
    let segments = (0..<6).map { index in
      TranscriptSegment(
        speaker: .others,
        start: Double(index) * 30,
        end: Double(index) * 30 + 30,
        text: index == 4
          ? "The offsite is in Lisbon this year." : "Filler talk about nothing, number \(index)."
      )
    }
    let long = Meeting(title: "Planning", status: .ready, segments: segments)
    let model = FakeLanguageModel { request in
      if request.user.contains("Transcript part:") {
        return request.user.contains("Lisbon")
          ? "[02:00] Others: The offsite is in Lisbon this year." : "NONE"
      }
      return "The offsite is in Lisbon."
    }
    let rig = MeetingRig(
      library: InMemoryLibrary(meetings: [long]),
      model: model,
      tuning: MeetingRig.tuning(notesCharacterLimit: 120)
    )
    #expect(try await rig.engine.ask("Where is the offsite?", about: long.id) == "The offsite is in Lisbon.")
    let last = try #require(rig.model.requests.last)
    #expect(rig.model.requests.count > 2)
    #expect(last.user.contains("The offsite is in Lisbon this year."))
    #expect(!last.user.contains("Filler talk"))
    #expect(!last.user.contains("NONE"))
  }

  @Test func saysSoWhenThereIsNothingToAnswerFrom() async throws {
    let empty = Meeting(title: "Quiet", status: .ready)
    let rig = MeetingRig(library: InMemoryLibrary(meetings: [empty]))
    let answer = try await rig.engine.ask("What was decided?", about: empty.id)
    #expect(answer.contains("no transcript or notes"))
    #expect(rig.model.requests.isEmpty)
    await #expect(throws: WisperError.notFound("The meeting")) {
      try await rig.engine.ask("What was decided?", about: UUID())
    }
  }
}
