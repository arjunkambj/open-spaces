import Foundation
import Testing
import WisperDomain
import WisperEngine

@MainActor
@Suite("Dictation: from key press to inserted text", .timeLimit(.minutes(1)))
struct DictationEngineTests {
  @Test func speakingPutsCleanTextInTheTargetAndInHistory() async throws {
    let target = FakeTextTarget(context: DictationContext(appName: "Mail", bundleID: "com.apple.mail"))
    let listening = Gate()
    let rig = try await Rig(
      transcriber: FakeTranscriber { _ in
        await listening.pass()
        return Transcript(text: " um so let's meet at three no four pm ")
      },
      model: FakeLanguageModel(text: "Let's meet at 4 pm."),
      target: target
    )
    #expect(rig.engine.phase == .idle)
    #expect(!rig.engine.isBusy)

    let before = Date()
    rig.engine.start()
    guard case .recording(let mode, let since, let handsFree) = rig.engine.phase else {
      Issue.record("start must show recording before it returns, got \(rig.engine.phase)")
      return
    }
    #expect(mode == .dictation)
    #expect(!handsFree)
    #expect(since >= before)
    #expect(rig.engine.isRecording)
    #expect(rig.engine.isBusy)

    let finishing = Task { await rig.engine.finish() }
    await listening.arrival()
    #expect(rig.engine.phase == .processing(mode: .dictation))
    #expect(!rig.engine.isRecording)
    #expect(rig.engine.isBusy)
    await listening.open()

    let result = try #require(await finishing.value)
    #expect(rig.engine.phase == .idle)
    #expect(await target.inserted == ["Let's meet at 4 pm."])
    #expect(result.text == "Let's meet at 4 pm.")
    #expect(result.rawText == "um so let's meet at three no four pm")
    #expect(result.mode == .dictation)
    #expect(result.duration == 3)
    #expect(result.appName == "Mail")
    #expect(result.bundleID == "com.apple.mail")
    #expect(result.failure == nil)
    #expect(result.createdAt >= before)
    #expect(await rig.history() == [result])
    #expect(rig.engine.last == result)
  }

  @Test func settingsReachTheMicrophoneTheTranscriberAndTheModel() async throws {
    let settings = Settings(
      transcriptionModel: "whisper-1",
      textModel: "gpt-test",
      language: "de",
      microphoneID: "usb-mic"
    )
    let rig = try await Rig(heard: "das ist ein kleiner Test", settings: settings)
    await rig.dictate()

    let capture = try #require(rig.capture.requests.first)
    #expect(rig.capture.requests.count == 1)
    #expect(capture.tracks == [.microphone])
    #expect(capture.microphoneID == "usb-mic")
    #expect(capture.chunkSeconds == nil)
    #expect(capture.directory == rig.audioFolder)

    let heard = try #require(rig.transcriber.requests.first)
    #expect(heard.model == "whisper-1")
    #expect(heard.language == "de")
    #expect(heard.audio.deletingLastPathComponent().path == rig.audioFolder.path)
    #expect(rig.prompt?.model == "gpt-test")
  }

  @Test func levelFollowsTheMicrophoneAndResets() async throws {
    let rig = try await Rig()
    #expect(rig.engine.level == 0)
    rig.engine.start()
    await rig.until { $0.level == 0.4 }
    let session = try #require(rig.capture.sessions.first)
    session.setLevel(0.9)
    await rig.until { $0.level == 0.9 }
    session.setLevel(7)
    await rig.until { $0.level == 1 }
    await rig.engine.finish()
    #expect(rig.engine.level == 0)
  }

  @Test func handsFreeIsShownInThePhase() async throws {
    let rig = try await Rig()
    rig.engine.start(mode: .command, handsFree: true)
    guard case .recording(.command, _, true) = rig.engine.phase else {
      Issue.record("expected a hands-free command recording, got \(rig.engine.phase)")
      return
    }
    await rig.microphoneOpen()
    rig.engine.cancel()
    #expect(rig.engine.phase == .idle)
  }

  // MARK: - One run at a time

  @Test func aSecondStartWhileRecordingIsIgnored() async throws {
    let rig = try await Rig()
    rig.engine.start()
    let first = rig.engine.phase
    rig.engine.start(mode: .command, handsFree: true)
    #expect(rig.engine.phase == first)
    await rig.engine.finish()
    #expect(rig.capture.requests.count == 1)
    #expect(await rig.history().count == 1)
  }

  @Test func startAndFinishWhileProcessingAreIgnored() async throws {
    let target = FakeTextTarget()
    let listening = Gate()
    let rig = try await Rig(
      transcriber: FakeTranscriber { _ in
        await listening.pass()
        return Transcript(text: "hello world")
      },
      target: target
    )
    rig.engine.start()
    let finishing = Task { await rig.engine.finish() }
    await listening.arrival()

    rig.engine.start()
    #expect(rig.engine.phase == .processing(mode: .dictation))
    #expect(await rig.engine.finish() == nil)
    #expect(rig.engine.phase == .processing(mode: .dictation))

    await listening.open()
    #expect(await finishing.value != nil)
    #expect(rig.capture.requests.count == 1)
    #expect(await target.inserted == ["Hello world"])
    #expect(await rig.history().count == 1)
  }

  @Test func finishWithNothingRecordingDoesNothing() async throws {
    let rig = try await Rig()
    #expect(await rig.engine.finish() == nil)
    #expect(rig.engine.phase == .idle)
    await rig.dictate()
    #expect(await rig.engine.finish() == nil)
    #expect(rig.capture.requests.count == 1)
    #expect(await rig.history().count == 1)
  }

  // MARK: - Nothing to write

  @Test func aRecordingTooShortToHoldSpeechIsDropped() async throws {
    let target = FakeTextTarget()
    let rig = try await Rig(capture: FakeAudioCapture(stopDuration: 0.1), target: target)
    #expect(await rig.dictate() == nil)
    #expect(rig.engine.phase == .idle)
    #expect(rig.transcriber.requests.isEmpty)
    #expect(await target.inserted.isEmpty)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.isEmpty)
    #expect(rig.engine.last == nil)
  }

  @Test(arguments: ["", "  \n "])
  func silenceIsNotAnError(heard: String) async throws {
    let target = FakeTextTarget()
    let rig = try await Rig(heard: heard, target: target)
    #expect(await rig.dictate() == nil)
    #expect(rig.engine.phase == .idle)
    #expect(rig.transcriber.requests.count == 1)
    #expect(rig.model.requests.isEmpty)
    #expect(await target.inserted.isEmpty)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.isEmpty)
  }

  @Test func aTranscriberThatReportsNoSpeechIsNotAnError() async throws {
    let rig = try await Rig(transcriber: FakeTranscriber { _ in throw WisperError.noSpeech })
    #expect(await rig.dictate() == nil)
    #expect(rig.engine.phase == .idle)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.isEmpty)
  }

  // MARK: - Quick taps and cancelling

  @Test func finishBeforeTheMicrophoneHasOpenedStillWorks() async throws {
    let target = FakeTextTarget()
    let opening = Gate()
    let rig = try await Rig(captureGate: opening, target: target)
    rig.engine.start()
    #expect(rig.engine.isRecording)
    #expect(rig.capture.sessions.isEmpty)

    // Runs on the main actor, so only once `finish` below is waiting for the microphone.
    let opener = Task { @MainActor in await opening.open() }
    let result = await rig.engine.finish()
    await opener.value

    #expect(result?.text == "Hello world")
    #expect(await target.inserted == ["Hello world"])
    #expect(rig.capture.sessions.count == 1)
    #expect(rig.capture.sessions.first?.isEnded == true)
    #expect(rig.engine.phase == .idle)
  }

  @Test func cancelBeforeTheMicrophoneHasOpenedClosesItAgain() async throws {
    let target = FakeTextTarget()
    let opening = Gate()
    let rig = try await Rig(captureGate: opening, target: target)
    rig.engine.start()
    rig.engine.cancel()
    #expect(rig.engine.phase == .idle)
    #expect(rig.capture.sessions.isEmpty)
    await opening.open()

    // The next dictation waits for the cancelled one to let go of the microphone.
    let next = await rig.dictate()
    #expect(next?.text == "Hello world")
    #expect(rig.capture.sessions.count == 2)
    #expect(rig.capture.sessions.first?.isEnded == true)
    #expect(await target.inserted == ["Hello world"])
    #expect(await rig.history().count == 1)
    #expect(rig.audioFiles.count == 1)
  }

  @Test func aNewRecordingWaitsForTheLastOneToLetGoOfTheMicrophone() async throws {
    let target = FakeTextTarget()
    let opening = Gate()
    let rig = try await Rig(captureGate: opening, target: target)
    // Tap, cancel, tap again, all before the first microphone has opened.
    rig.engine.start()
    rig.engine.cancel()
    rig.engine.start()
    let finishing = Task { await rig.engine.finish() }
    await opening.arrival()
    await opening.open()

    #expect(await finishing.value?.text == "Hello world")
    #expect(rig.capture.sessions.count == 2)
    #expect(rig.capture.sessions.map(\.isEnded) == [true, true])
    #expect(rig.slowCapture?.overlaps.value == 0)
    #expect(await target.inserted == ["Hello world"])
  }

  @Test func cancelWhileRecordingDiscardsEverything() async throws {
    let target = FakeTextTarget()
    let rig = try await Rig(target: target)
    rig.engine.start()
    await rig.microphoneOpen()
    let session = try #require(rig.capture.sessions.first)

    rig.engine.cancel()
    #expect(rig.engine.phase == .idle)
    #expect(rig.engine.level == 0)
    #expect(await rig.engine.finish() == nil)
    // `chunks` ends when the session has been cancelled.
    for await _ in session.chunks {}

    #expect(session.isEnded)
    #expect(rig.transcriber.requests.isEmpty)
    #expect(await target.inserted.isEmpty)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.isEmpty)
  }

  @Test func cancelWhileProcessingInsertsAndSavesNothing() async throws {
    let target = FakeTextTarget()
    let listening = Gate()
    let rig = try await Rig(
      transcriber: FakeTranscriber { _ in
        await listening.pass()
        return Transcript(text: "please do not insert this")
      },
      target: target
    )
    rig.engine.start()
    let finishing = Task { await rig.engine.finish() }
    await listening.arrival()
    #expect(rig.audioFiles.count == 1)

    rig.engine.cancel()
    #expect(rig.engine.phase == .idle)
    await listening.open()

    #expect(await finishing.value == nil)
    #expect(rig.engine.phase == .idle)
    #expect(rig.model.requests.isEmpty)
    #expect(await target.inserted.isEmpty)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.isEmpty)
    #expect(rig.engine.last == nil)

    // The engine is ready for the next one.
    #expect(await rig.dictate() != nil)
    #expect(await target.inserted.count == 1)
  }

  @Test func cancelJustBeforeTheTextGoesInDiscardsIt() async throws {
    let typing = Gate()
    let target = ScriptedTarget(gate: typing)
    let rig = try await Rig(target: target)
    rig.engine.start()
    let finishing = Task { await rig.engine.finish() }
    await typing.arrival()

    rig.engine.cancel()
    await typing.open()

    #expect(await finishing.value == nil)
    #expect(rig.engine.phase == .idle)
    #expect(await target.inserted.isEmpty)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.isEmpty)
  }

  @Test func cancelWithNothingGoingOnDoesNothing() async throws {
    let rig = try await Rig()
    rig.engine.cancel()
    #expect(rig.engine.phase == .idle)
    let done = await rig.dictate()
    rig.engine.cancel()
    #expect(rig.engine.last == done)
    #expect(await rig.history().count == 1)
  }

  // MARK: - Limits and lifetime

  @Test func aRecordingThatReachesTheLimitFinishesByItself() async throws {
    let target = FakeTextTarget()
    let rig = try await Rig(target: target)
    #expect(rig.engine.recordingLimit == 600)
    rig.engine.recordingLimit = 0.02
    rig.engine.start(handsFree: true)
    await rig.until { $0.last != nil && $0.phase == .idle }
    #expect(await target.inserted == ["Hello world"])
    #expect(await rig.history().count == 1)
    #expect(rig.capture.sessions.first?.isEnded == true)
  }

  @Test func theLimitOfAFinishedRecordingDoesNotEndTheNextOne() async throws {
    let rig = try await Rig()
    rig.engine.recordingLimit = 0.02
    rig.engine.start()
    rig.engine.cancel()
    rig.engine.recordingLimit = 600
    rig.engine.start()
    await rig.microphoneOpen()
    try await Task.sleep(for: .seconds(0.1))
    #expect(rig.engine.isRecording)
    rig.engine.cancel()
  }

  @Test(arguments: [Double.infinity, .nan, 1e12])
  func aLimitThatIsNotARealLengthMeansNoLimit(limit: Double) async throws {
    let rig = try await Rig()
    rig.engine.recordingLimit = limit
    rig.engine.start(handsFree: true)
    await rig.microphoneOpen()
    #expect(rig.engine.isRecording)
    #expect(await rig.engine.finish() != nil)
  }

  @Test func anEngineThatIsDroppedWhileRecordingClosesTheMicrophone() async throws {
    let capture = FakeAudioCapture()
    weak var dropped: DictationEngine?
    do {
      let rig = try await Rig(capture: capture)
      dropped = rig.engine
      rig.engine.start()
      await rig.microphoneOpen()
    }
    #expect(dropped == nil)
    let session = try #require(capture.sessions.first)
    // The next loudness value wakes the recording, which finds its engine gone.
    session.setLevel(0.5)
    for await _ in session.chunks {}
    #expect(session.isEnded)
  }

  @Test func aFinishedEngineIsReleased() async throws {
    weak var dropped: DictationEngine?
    do {
      let rig = try await Rig()
      dropped = rig.engine
      await rig.dictate()
      rig.engine.start()
      await rig.microphoneOpen()
      rig.engine.cancel()
    }
    #expect(dropped == nil)
  }
}
