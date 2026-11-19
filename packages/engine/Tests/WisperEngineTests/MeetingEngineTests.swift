import Foundation
import Testing
import WisperDomain

@testable import WisperEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MeetingEngineTests {
  // MARK: Recording

  @Test func recordsAMeetingFromStartToReady() async throws {
    let reachedNotes = MeetingGate()
    let releaseNotes = MeetingGate()
    let transcriber = FakeTranscriber { request in
      switch MeetingRig.name(of: request) {
      case "microphone-0":
        Transcript(
          text: "Hello team. Let's begin.",
          segments: [
            Transcript.Segment(start: 1, end: 4, text: " Hello team. "),
            Transcript.Segment(start: 5, end: 9, text: "Let's begin."),
            Transcript.Segment(start: 9, end: 10, text: "  "),
          ]
        )
      case "system-0": Transcript(text: "We are on track for Friday.")
      case "system-1": Transcript(text: "Thanks everyone, bye.")
      default: Transcript(text: "")
      }
    }
    let model = FakeLanguageModel { _ in
      reachedNotes.open()
      await releaseNotes.wait()
      return MeetingRig.notesJSON()
    }
    let rig = MeetingRig(
      settings: Settings(
        userName: "Alex",
        transcriptionModel: "whisper-1",
        language: "en",
        microphoneID: "usb"
      ),
      // The user's own name is also in the dictionary; it is passed on once.
      words: [
        DictionaryWord(text: "Kubernetes", createdAt: Date(timeIntervalSince1970: 2_000)),
        DictionaryWord(text: "alex", createdAt: Date(timeIntervalSince1970: 1_000)),
      ],
      transcriber: transcriber,
      model: model
    )

    let id = try await rig.engine.start()
    #expect(rig.engine.isRecording)
    #expect(rig.engine.live?.meetingID == id)
    let recording = try await rig.meeting(id)
    #expect(recording.status == .recording)
    #expect(recording.title == MeetingEngine.placeholderTitle(for: recording.startedAt))
    #expect(recording.title.hasPrefix("Meeting, "))
    #expect(rig.engine.live?.title == recording.title)

    let request = try #require(rig.capture.requests.first)
    #expect(request.tracks == [.microphone, .system])
    #expect(request.microphoneID == "usb")
    #expect(request.chunkSeconds == 30)
    #expect(request.directory == (try await rig.library.audioDirectory(forMeeting: id)))

    try rig.session.setLevel(0.8)
    await rig.until { rig.engine.level == 0.8 }

    try rig.session.emit(duration: 30)
    await rig.engine.stop()

    // `stop` returns with the meeting saved as processing; the rest happens behind it.
    #expect(!rig.engine.isRecording)
    #expect(rig.engine.live == nil)
    #expect(rig.engine.level == 0)
    #expect(rig.engine.processing == [id])
    await reachedNotes.wait()
    let processing = try await rig.meeting(id)
    #expect(processing.status == .processing)
    #expect(processing.endedAt != nil)
    #expect(processing.segments.count == 4)

    releaseNotes.open()
    let meeting = try await rig.finished(id)
    #expect(meeting.status == .ready)
    #expect(meeting.failure == nil)
    #expect(meeting.endedAt == processing.endedAt)
    #expect(meeting.segments.map(\.speaker) == [.others, .me, .me, .others])
    #expect(meeting.segments.map(\.start) == [0, 1, 5, 30])
    #expect(meeting.segments.map(\.end) == [30, 4, 9, 33])
    #expect(
      meeting.segments.map(\.text) == [
        "We are on track for Friday.", "Hello team.", "Let's begin.", "Thanks everyone, bye.",
      ]
    )
    #expect(meeting.title == "Launch planning")
    #expect(meeting.notes?.summary == "The team talked about the launch.")

    // Every chunk went to the transcriber once, with the user's model, language and words.
    #expect(
      rig.transcriber.requests.map(MeetingRig.name(of:)).sorted()
        == ["microphone-0", "microphone-1", "system-0", "system-1"]
    )
    for request in rig.transcriber.requests {
      #expect(request.model == "whisper-1")
      #expect(request.language == "en")
      #expect(request.vocabulary == ["Kubernetes", "alex"])
    }
    // The audio is kept by default.
    #expect(try await rig.audioFiles(id).contains("microphone-0.m4a"))
  }

  @Test func showsAndSavesTheTranscriptWhileRecording() async throws {
    let rig = MeetingRig(
      transcriber: MeetingRig.hears([
        "microphone-0": "Good morning.", "system-0": "Morning, how are you?",
        "microphone-1": "Shall we start with the budget?",
      ])
    )
    let id = try await rig.engine.start()
    #expect(rig.engine.live?.segments == [])

    try rig.session.emit(duration: 20)
    await rig.until { rig.engine.live?.segments.count == 2 }
    #expect(rig.engine.live?.segments.map(\.speaker) == [.me, .others])

    try rig.session.emit(duration: 20)
    await rig.until { rig.engine.live?.segments.count == 3 }
    let live = try #require(rig.engine.live)
    #expect(live.segments.map(\.start) == [0, 0, 20])
    #expect(live.segments.last?.text == "Shall we start with the budget?")

    // The library has it too, while the meeting is still being recorded.
    let stored = try await rig.meeting(id) { $0.segments.count == 3 }
    #expect(stored.status == .recording)
    #expect(stored.segments == live.segments)

    await rig.engine.stop()
    let meeting = try await rig.finished(id)
    #expect(meeting.status == .ready)
    // Segments keep their identity from the live transcript to the stored meeting.
    #expect(Array(meeting.segments.prefix(3)) == live.segments)
  }

  @Test func onlyOneMeetingIsRecordedAtATime() async throws {
    let rig = MeetingRig()
    let id = try await rig.engine.start(title: "  Standup ")
    #expect(try await rig.meeting(id).title == "Standup")

    await #expect(throws: WisperError.self) { try await rig.engine.start() }
    #expect(rig.engine.live?.meetingID == id)
    #expect(try await rig.library.meetings().count == 1)
    #expect(rig.capture.sessions.count == 1)

    await rig.engine.stop()
    _ = try await rig.finished(id)
    // Stopping again does nothing, and a new meeting can be started.
    await rig.engine.stop()
    let next = try await rig.engine.start()
    #expect(next != id)
    await rig.engine.stop()
    _ = try await rig.finished(next)
  }

  @Test func toggleStartsThenStops() async throws {
    let rig = MeetingRig(transcriber: MeetingRig.hears(["microphone-0": "A quick note to self."]))
    await rig.engine.toggle()
    let id = try #require(rig.engine.live?.meetingID)
    #expect(rig.engine.lastError == nil)

    await rig.engine.toggle()
    #expect(!rig.engine.isRecording)
    let meeting = try await rig.finished(id)
    #expect(meeting.status == .ready)
    #expect(meeting.segments.map(\.text) == ["A quick note to self."])
  }

  @Test func toggleReportsWhyItCouldNotStart() async throws {
    let rig = MeetingRig(capture: FakeAudioCapture(failure: .permissionDenied(.microphone)))
    await rig.engine.toggle()
    #expect(!rig.engine.isRecording)
    #expect(rig.engine.lastError == WisperError.permissionDenied(.microphone).localizedDescription)
    #expect(try await rig.library.meetings().isEmpty)
  }

  // MARK: Capture problems

  @Test(
    arguments: [
      WisperError.permissionDenied(.systemAudio),
      .captureFailed("System audio could not be recorded (start, code -1)."),
    ]
  )
  func fallsBackToTheMicrophoneAndSaysSoWhenSystemAudioCannotBeRecorded(refusal: WisperError) async throws {
    let fake = FakeAudioCapture()
    let rig = MeetingRig(
      capture: fake,
      startingCapture: MeetingPickyCapture(inner: fake) { $0.tracks.contains(.system) ? refusal : nil },
      transcriber: MeetingRig.hears(["microphone-0": "Only my side was recorded."])
    )
    let id = try await rig.engine.start()
    #expect(rig.capture.requests.map(\.tracks) == [[.microphone]])
    // The user is told, with the reason: an hour of only their own side is not what they wanted.
    let reason =
      refusal == .permissionDenied(.systemAudio)
      ? "System audio recording access is needed. Turn it on in System Settings."
      : "System audio could not be recorded (start, code -1)."
    #expect(rig.engine.lastError == "Only your microphone is being recorded. " + reason)

    await rig.engine.stop()
    let meeting = try await rig.finished(id)
    #expect(meeting.status == .ready)
    #expect(meeting.segments.map(\.speaker) == [.me])
  }

  @Test func staysQuietWhereSystemAudioCannotBeRecordedAtAll() async throws {
    // An iPhone: there is nothing to ask for, and nothing the user could do about it.
    let fake = FakeAudioCapture()
    let asked = MeetingSwitch(false)
    let rig = MeetingRig(
      capture: fake,
      startingCapture: MeetingPickyCapture(inner: fake) { request in
        guard request.tracks.contains(.system) else { return nil }
        asked.set(true)
        return .captureFailed("iPhone and iPad cannot record the sound of other apps.")
      },
      tuning: MeetingRig.tuning(recordsSystemAudio: false)
    )
    let id = try await rig.engine.start()
    #expect(!asked.isOn)
    #expect(rig.capture.requests.map(\.tracks) == [[.microphone]])
    #expect(rig.engine.lastError == nil)
    await rig.engine.stop()
    _ = try await rig.finished(id)
  }

  @Test func aMicrophoneThatFailsIsNotMistakenForMissingSystemAudio() async throws {
    let rig = MeetingRig(capture: FakeAudioCapture(failure: .captureFailed("No microphone was found.")))
    await #expect(throws: WisperError.captureFailed("No microphone was found.")) {
      try await rig.engine.start()
    }
    #expect(rig.engine.lastError == nil)
    #expect(try await rig.library.meetings().isEmpty)
  }

  @Test func recordsOnlyTheMicrophoneWhenSystemAudioIsTurnedOff() async throws {
    let rig = MeetingRig(
      settings: Settings(meetings: MeetingSettings(captureSystemAudio: false))
    )
    let id = try await rig.engine.start()
    #expect(rig.capture.requests.map(\.tracks) == [[.microphone]])
    await rig.engine.stop()
    _ = try await rig.finished(id)
  }

  @Test func aDeniedMicrophoneLeavesNoMeetingBehind() async throws {
    let rig = MeetingRig(capture: FakeAudioCapture(failure: .permissionDenied(.microphone)))
    await #expect(throws: WisperError.permissionDenied(.microphone)) { try await rig.engine.start() }
    #expect(!rig.engine.isRecording)
    #expect(rig.engine.processing.isEmpty)
    #expect(try await rig.library.meetings().isEmpty)
  }

  // MARK: Echo

  @Test func dropsWhatTheMicrophoneHeardFromTheSpeakers() async throws {
    let rig = MeetingRig(
      transcriber: MeetingRig.hears([
        // The whole chunk is the others, heard again through the speakers.
        "system-0": "We are on track for the launch on Friday, and billing is the only risk.",
        "microphone-0": "we are on track for the launch on friday and billing is the only risk",
        // Their sentence, then mine.
        "system-1": "Can you send the onboarding copy to design by Wednesday?",
        "microphone-1":
          "Can you send the onboarding copy to design by Wednesday? Yes, I will send it tomorrow.",
      ])
    )
    let id = try await rig.engine.start()
    try rig.session.emit(duration: 30)
    try rig.session.emit(duration: 30)
    await rig.until { rig.engine.live?.segments.count == 3 }
    #expect(
      rig.engine.live?.segments.filter { $0.speaker == .me }.map(\.text) == ["Yes, I will send it tomorrow."]
    )

    await rig.engine.stop()
    let meeting = try await rig.finished(id)
    #expect(
      meeting.segments.map(\.text) == [
        "We are on track for the launch on Friday, and billing is the only risk.",
        "Can you send the onboarding copy to design by Wednesday?",
        "Yes, I will send it tomorrow.",
      ]
    )
    #expect(meeting.segments.map(\.speaker) == [.others, .others, .me])
    // What is left of my chunk starts after the part that was the others talking.
    let mine = try #require(meeting.segments.last)
    #expect(mine.start > 45 && mine.start < 60)
    #expect(mine.end == 60)
  }

  @Test func dropsAnEchoWithAMisheardWord() async throws {
    let rig = MeetingRig(
      transcriber: MeetingRig.hears([
        "system-0": "The quarterly numbers look better than we expected, mostly thanks to the new pricing.",
        "microphone-0":
          "The quarterly numbers look better than we accepted, mostly thanks to the new pricing.",
      ])
    )
    let id = try await rig.engine.start()
    await rig.engine.stop()
    let meeting = try await rig.finished(id)
    #expect(meeting.segments.map(\.speaker) == [.others])
  }

  @Test func keepsWhatTheUserReallySaid() async throws {
    let rig = MeetingRig(
      transcriber: MeetingRig.hears([
        "system-0": "We are on track for the launch on Friday, and billing is the only risk.",
        // A short reply made of the others' words.
        "microphone-0": "On track for Friday then.",
        "system-1": "The design review moved to Thursday afternoon.",
        // Shares many words, but says something else.
        "microphone-1": "Is the launch on Friday the only risk for billing, or are we on a different track?",
        "system-2": "",
        // The same words as the others used, but a minute later: not an echo.
        "microphone-2": "We are on track for the launch on Friday, and billing is the only risk.",
      ])
    )
    let id = try await rig.engine.start()
    try rig.session.emit(duration: 30)
    try rig.session.emit(duration: 30)
    try rig.session.emit(duration: 30)
    await rig.engine.stop()
    let meeting = try await rig.finished(id)
    #expect(
      meeting.segments.filter { $0.speaker == .me }.map(\.text) == [
        "On track for Friday then.",
        "Is the launch on Friday the only risk for billing, or are we on a different track?",
        "We are on track for the launch on Friday, and billing is the only risk.",
      ]
    )
  }

  // MARK: Transcription problems

  @Test func aChunkThatKeepsFailingWaitsForARetry() async throws {
    let offline = MeetingSwitch(true)
    let transcriber = FakeTranscriber { request in
      switch MeetingRig.name(of: request) {
      case "system-0":
        if offline.isOn { throw WisperError.network("offline") }
        return Transcript(text: "The budget was approved last week.")
      case "microphone-0": return Transcript(text: "Let's talk about the budget.")
      default: return Transcript(text: "")
      }
    }
    let rig = MeetingRig(
      settings: Settings(userName: "Alex", meetings: MeetingSettings(keepAudio: false)),
      transcriber: transcriber
    )
    let id = try await rig.engine.start()
    try rig.session.emit(duration: 30)
    // The good chunk shows up; the bad one does not hold it back.
    await rig.until { rig.engine.live?.segments.count == 1 }
    await rig.engine.stop()

    let partial = try await rig.finished(id)
    #expect(partial.status == .ready)
    #expect(partial.segments.map(\.text) == ["Let's talk about the budget."])
    #expect(partial.failure?.hasPrefix("Part of this meeting could not be transcribed.") == true)
    #expect(partial.failure?.contains(WisperError.network("offline").localizedDescription) == true)
    // Two tries while recording, two more when the meeting was finished.
    #expect(rig.transcriber.requests.filter { MeetingRig.name(of: $0) == "system-0" }.count == 4)
    // The audio stays, although the user does not keep audio, because it is still needed.
    #expect(try await rig.audioFiles(id).contains("system-0.m4a"))

    // Still offline: the retry says so and nothing is lost.
    await #expect(throws: WisperError.network("offline")) { try await rig.engine.retry(id) }
    #expect(try await rig.meeting(id).segments.count == 1)
    #expect(rig.engine.processing.isEmpty)

    offline.set(false)
    try await rig.engine.retry(id)
    let meeting = try await rig.meeting(id)
    #expect(meeting.status == .ready)
    #expect(meeting.failure == nil)
    #expect(
      meeting.segments.map(\.text) == ["Let's talk about the budget.", "The budget was approved last week."]
    )
    #expect(meeting.segments.map(\.speaker) == [.me, .others])
    // The good chunk was never transcribed again.
    #expect(rig.transcriber.requests.filter { MeetingRig.name(of: $0) == "microphone-0" }.count == 1)
    // Now that everything is transcribed the audio goes.
    #expect(try await rig.audioFiles(id).isEmpty)
    // The notes were written again from the full transcript.
    #expect(rig.model.requests.last?.user.contains("The budget was approved last week.") == true)
  }

  @Test func aMeetingWhereNothingCouldBeTranscribedFails() async throws {
    let broken = MeetingSwitch(true)
    let transcriber = FakeTranscriber { request in
      if broken.isOn { throw WisperError.invalidAPIKey }
      return Transcript(text: MeetingRig.name(of: request) == "microphone-0" ? "Testing, one two three." : "")
    }
    let rig = MeetingRig(
      settings: Settings(meetings: MeetingSettings(captureSystemAudio: false, keepAudio: false)),
      transcriber: transcriber
    )
    let id = try await rig.engine.start()
    await rig.engine.stop()
    let failed = try await rig.finished(id)
    #expect(failed.status == .failed)
    #expect(failed.segments.isEmpty)
    #expect(
      failed.failure
        == "This meeting could not be transcribed. " + WisperError.invalidAPIKey.localizedDescription
    )
    #expect(failed.notes == nil)
    #expect(rig.model.requests.isEmpty)
    // A key that is refused is not tried again and again.
    #expect(rig.transcriber.requests.count == 2)
    #expect(try await rig.audioFiles(id).contains("microphone-0.m4a"))

    broken.set(false)
    try await rig.engine.retry(id)
    let meeting = try await rig.meeting(id)
    #expect(meeting.status == .ready)
    #expect(meeting.failure == nil)
    #expect(meeting.segments.map(\.text) == ["Testing, one two three."])
    #expect(meeting.notes != nil)
    #expect(try await rig.audioFiles(id).isEmpty)
  }

  @Test func anAnswerThatIsFinalStopsTheQueueUntilTheSettingIsFixed() async throws {
    // A typo in the model name: the server says no, and would say no to every chunk.
    let typo = MeetingSwitch(true)
    let refusal = WisperError.server(status: 404, message: "The model `gpt-transcrib` does not exist")
    let transcriber = FakeTranscriber { request in
      if typo.isOn { throw refusal }
      return Transcript(text: "Said in \(MeetingRig.name(of: request)).")
    }
    let rig = MeetingRig(
      settings: Settings(meetings: MeetingSettings(keepAudio: false)),
      transcriber: transcriber
    )
    let id = try await rig.engine.start()
    // Eleven chunks on each of two tracks by the time the meeting is stopped.
    for _ in 0..<10 { try rig.session.emit(duration: 30) }
    await rig.engine.stop()

    let failed = try await rig.finished(id)
    #expect(failed.status == .failed)
    // A plain failure that names the cause.
    #expect(failed.failure == "This meeting could not be transcribed. " + refusal.localizedDescription)
    // Two answers while recording were enough, and one handful when the meeting was finished:
    // not two rounds of tries for each of the 22 chunks.
    #expect(rig.transcriber.requests.count <= 8)
    let asked = Dictionary(grouping: rig.transcriber.requests.map(MeetingRig.name(of:)), by: { $0 })
    #expect(asked.values.allSatisfy { $0.count <= 2 })
    // Nothing was transcribed, so the audio stays although the user does not keep audio.
    #expect(try await rig.audioFiles(id).filter { $0.hasSuffix(".m4a") }.count == 22)

    // The same answer again does not start a storm either.
    await #expect(throws: refusal) { try await rig.engine.retry(id) }
    #expect(rig.transcriber.requests.count <= 12)

    // The setting is fixed: everything goes through.
    typo.set(false)
    try await rig.engine.retry(id)
    let meeting = try await rig.meeting(id)
    #expect(meeting.status == .ready)
    #expect(meeting.failure == nil)
    #expect(meeting.segments.count == 22)
    #expect(try await rig.audioFiles(id).isEmpty)
  }

  @Test func oneFileTheServerWillNotTakeDoesNotStopTheOthers() async throws {
    let refusal = WisperError.server(status: 400, message: "The audio file could not be decoded")
    let rig = MeetingRig(
      settings: Settings(meetings: MeetingSettings(captureSystemAudio: false)),
      transcriber: FakeTranscriber { request in
        if MeetingRig.name(of: request) == "microphone-0" { throw refusal }
        return Transcript(text: "Said in \(MeetingRig.name(of: request)).")
      }
    )
    let id = try await rig.engine.start()
    try rig.session.emit(duration: 30)
    try rig.session.emit(duration: 30)
    // The transcript keeps moving while the meeting goes on.
    await rig.until { rig.engine.live?.segments.count == 1 }
    try rig.session.emit(duration: 30)
    await rig.until { rig.engine.live?.segments.count == 2 }
    await rig.engine.stop()

    let meeting = try await rig.finished(id)
    #expect(meeting.status == .ready)
    #expect(meeting.segments.count == 3)
    #expect(
      meeting.failure == "Part of this meeting could not be transcribed. " + refusal.localizedDescription
    )
    // A final answer is not asked for again and again: once while recording, once at the end.
    #expect(rig.transcriber.requests.filter { MeetingRig.name(of: $0) == "microphone-0" }.count == 2)
  }

  @Test func aMeetingWithNoSpeechIsReadyAndEmpty() async throws {
    let rig = MeetingRig(
      transcriber: FakeTranscriber { request in
        // Both ways a transcriber says "nothing was said".
        if request.audio.lastPathComponent.hasPrefix("system") { throw WisperError.noSpeech }
        return Transcript(text: "  ")
      }
    )
    let id = try await rig.engine.start()
    try rig.session.emit(duration: 30)
    await rig.engine.stop()
    let meeting = try await rig.finished(id)
    #expect(meeting.status == .ready)
    #expect(meeting.failure == nil)
    #expect(meeting.segments.isEmpty)
    #expect(meeting.notes == nil)
    #expect(rig.model.requests.isEmpty)
    #expect(rig.transcriber.requests.count == 4)
  }

  @Test func retryLeavesAFinishedMeetingAlone() async throws {
    let rig = MeetingRig(transcriber: MeetingRig.hears(["microphone-0": "All done here."]))
    let id = try await rig.engine.start()
    await rig.engine.stop()
    let before = try await rig.finished(id)
    let asked = (rig.transcriber.requests.count, rig.model.requests.count)

    try await rig.engine.retry(id)
    #expect(try await rig.meeting(id) == before)
    #expect((rig.transcriber.requests.count, rig.model.requests.count) == asked)
    await #expect(throws: WisperError.notFound("The meeting")) { try await rig.engine.retry(UUID()) }
  }

  @Test func aMeetingDeletedWhileRecordingStaysDeleted() async throws {
    let rig = MeetingRig(transcriber: MeetingRig.hears(["microphone-0": "Never mind."]))
    let id = try await rig.engine.start()
    try rig.session.emit(duration: 30)
    // Wait for the engine's own save of the transcript so far, so the delete comes after it.
    _ = try await rig.meeting(id) { $0.segments.count == 1 }
    await rig.library.deleteMeeting(id)

    await rig.engine.stop()
    await rig.until { rig.engine.processing.isEmpty }
    #expect(!rig.engine.isRecording)
    #expect(try await rig.library.meetings().isEmpty)
    #expect(try await rig.audioFiles(id).isEmpty)
  }

  // MARK: Recovery

  @Test func finishesAMeetingTheAppQuitInTheMiddleOf() async throws {
    // The first run records one chunk per track, transcribes the microphone and then "quits".
    let first = MeetingRig(
      transcriber: FakeTranscriber { request in
        if MeetingRig.name(of: request) == "system-0" { throw WisperError.network("offline") }
        return Transcript(text: "I think we should hire two more people.")
      }
    )
    let id = try await first.engine.start()
    try first.session.emit(duration: 30)
    _ = try await first.meeting(id) { $0.segments.count == 1 }
    await first.until { first.transcriber.requests.count == 3 }

    // The next launch finds the meeting still marked as recording.
    let second = MeetingRig(
      library: first.library,
      transcriber: MeetingRig.hears(["system-0": "Two sounds right to me."])
    )
    await second.engine.recoverUnfinished()
    #expect(second.engine.processing == [id])
    #expect(try await second.meeting(id).status == .processing)

    let meeting = try await second.finished(id)
    #expect(meeting.status == .ready)
    #expect(meeting.failure == nil)
    #expect(meeting.endedAt == meeting.startedAt.addingTimeInterval(30))
    #expect(
      meeting.segments.map(\.text) == ["I think we should hire two more people.", "Two sounds right to me."]
    )
    #expect(meeting.segments.map(\.speaker) == [.me, .others])
    #expect(meeting.segments.map(\.end) == [30, 30])
    // Only what was missing was transcribed.
    #expect(second.transcriber.requests.map(MeetingRig.name(of:)) == ["system-0"])
    #expect(meeting.notes != nil)
    #expect(meeting.title == "Launch planning")
  }

  @Test func recoversMeetingsLeftWithoutAnyAudio() async throws {
    let start = Date(timeIntervalSinceNow: -3_600)
    let stuck = Meeting(
      title: "Interview",
      startedAt: start,
      status: .processing,
      segments: [TranscriptSegment(speaker: .me, start: 2, end: 12, text: "Tell me about your last project.")]
    )
    let ready = Meeting(title: "Old one", startedAt: start.addingTimeInterval(-600), status: .ready)
    let failed = Meeting(
      title: "Broken",
      startedAt: start.addingTimeInterval(-900),
      status: .failed,
      failure: "x"
    )
    let rig = MeetingRig(library: InMemoryLibrary(meetings: [stuck, ready, failed]))

    await rig.engine.recoverUnfinished()
    #expect(rig.engine.processing == [stuck.id])
    let meeting = try await rig.finished(stuck.id)
    #expect(meeting.status == .ready)
    #expect(meeting.title == "Interview")
    #expect(meeting.segments == stuck.segments)
    #expect(meeting.endedAt == start.addingTimeInterval(12))
    #expect(meeting.notes != nil)
    // Meetings that are not stuck are left alone.
    #expect(try await rig.meeting(ready.id) == ready)
    #expect(try await rig.meeting(failed.id) == failed)
    #expect(rig.transcriber.requests.isEmpty)

    // A failed meeting whose recording is gone cannot be retried, and says so.
    await #expect(throws: WisperError.self) { try await rig.engine.retry(failed.id) }
    #expect(try await rig.meeting(failed.id).status == .failed)
  }

  @Test func recoveryDoesNotTouchTheMeetingBeingRecorded() async throws {
    let rig = MeetingRig(transcriber: MeetingRig.hears(["microphone-0": "Still going."]))
    let id = try await rig.engine.start()
    await rig.engine.recoverUnfinished()
    #expect(rig.engine.processing.isEmpty)
    #expect(rig.engine.live?.meetingID == id)
    #expect(try await rig.meeting(id).status == .recording)
    await rig.engine.stop()
    #expect(try await rig.finished(id).status == .ready)
  }

  @Test func aMeetingThatLostAudioForGoodCannotBeRetried() {
    var meeting = Meeting(title: "Sync", status: .ready)
    #expect(!MeetingEngine.canRetry(meeting))
    meeting.failure = "Part of this meeting could not be transcribed."
    #expect(MeetingEngine.canRetry(meeting))
    meeting.failure = MeetingEngine.partLost
    #expect(!MeetingEngine.canRetry(meeting))
    meeting.failure = nil
    meeting.status = .failed
    #expect(MeetingEngine.canRetry(meeting))
  }
}
