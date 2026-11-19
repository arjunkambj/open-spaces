import Foundation
import Testing
import WisperDomain

@testable import WisperEngine

/// A capture whose live sound stops short of its file, as when a reader fell far behind.
private struct ShortOfSound: CaptureSession {
  let levels = AsyncStream<Float> { $0.finish() }
  let chunks = AsyncStream<AudioChunk> { $0.finish() }
  let frames: AsyncStream<AudioFrames>

  /// Hands over `seconds` of sound and ends.
  init(seconds: Double) {
    frames = AsyncStream { feed in
      feed.yield(
        AudioFrames(samples: [Float](repeating: 0, count: Int(seconds * 16_000)), sampleRate: 16_000)
      )
      feed.finish()
    }
  }

  func stop() async {}
  func cancel() async {}
}

/// A live transcriber whose `open` does not return until the test lets it.
private struct SlowToOpen: LiveTranscriber {
  let gate = Gate()

  func open(_ request: LiveTranscriptionRequest) async throws -> any LiveTranscription {
    await gate.pass()
    throw WisperError.network("too late")
  }
}

@MainActor
@Suite("Dictation: words written while the person speaks, with the file behind them", .timeLimit(.minutes(1)))
struct DictationLiveTests {
  nonisolated static let fileWords = "the words from the file"
  nonisolated static let liveWords = "the words heard live"

  // MARK: - The live side has the words

  @Test func wordsHeardLiveAreUsedAndTheFileIsNotSent() async throws {
    let live = FakeLiveTranscriber(text: " \(Self.liveWords) ")
    let target = FakeTextTarget()
    let rig = try await Rig(
      heard: Self.fileWords,
      settings: Settings(userName: "Alex", transcriptionModel: "gpt-live-transcribe", language: "en"),
      words: [DictionaryWord(text: "Kubernetes")],
      live: live,
      target: target
    )

    let done = try #require(await rig.dictate())

    #expect(done.rawText == Self.liveWords)
    #expect(done.text == Self.liveWords)
    #expect(await target.inserted == [Self.liveWords])
    #expect(done.timing?.path == .live)
    #expect(rig.transcriber.requests.isEmpty)

    // It was asked the way the file transcriber is asked.
    let request = try #require(live.requests.first)
    #expect(live.requests.count == 1)
    #expect(request.model == "gpt-live-transcribe")
    #expect(request.language == "en")
    #expect(request.vocabulary == ["Kubernetes", "Alex"])

    // And it was handed all three seconds of the recording, then finished once.
    let session = try #require(live.sessions.first)
    #expect(session.sampleCount == 3 * 16_000)
    #expect(session.isFinished)

    // The recording was still written to its file: the capture was asked for both.
    #expect(rig.capture.requests.first?.liveFrames == true)
    #expect(rig.capture.requests.first?.chunkSeconds == nil)
    #expect(await rig.history() == [done])
  }

  @Test func theRestOfTheWorkIsTheSameAsForAFile() async throws {
    let rig = try await Rig(
      words: [DictionaryWord(text: "Kubernetes", replaces: "cooper netties")],
      snippets: [Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/alex")],
      live: FakeLiveTranscriber(text: "um deploy cooper netties and send my calendar link"),
      model: FakeLanguageModel(text: "Deploy Kubernetes and send my calendar link.")
    )

    let done = try #require(await rig.dictate())

    // Dictionary, tidying and snippets all ran on the live words.
    #expect(done.text == "Deploy Kubernetes and send https://cal.example.com/alex.")
    #expect(transcript(in: try #require(rig.prompt).user)?.contains("Kubernetes") == true)
  }

  @Test func withoutALiveTranscriberNothingChanges() async throws {
    let rig = try await Rig(heard: Self.fileWords)

    let done = try #require(await rig.dictate())

    #expect(done.timing?.path == .file)
    #expect(rig.capture.requests.first?.liveFrames == false)
    #expect(rig.engine.partialText.isEmpty)
  }

  /// Tests of "the head start is not waited out" use a 45 s recording, whose head start is
  /// 6 s, and allow this long: a busy test machine can add a second or two to anything.
  static let wellBeforeTheHeadStart: Duration = .seconds(4)

  // MARK: - The file takes over

  @Test func aLiveSessionThatCannotBeOpenedLeavesTheFileToDoIt() async throws {
    let live = FakeLiveTranscriber(openFailure: .network("live transcription is not available")) { _ in
      Transcript(text: "never asked")
    }
    // A long recording: its head start would be 6 s, far more than a busy test machine adds.
    let rig = try await Rig(heard: Self.fileWords, capture: FakeAudioCapture(stopDuration: 45), live: live)

    let began = ContinuousClock.now
    let done = try #require(await rig.dictate())

    #expect(done.rawText == Self.fileWords)
    #expect(done.timing?.path == .file)
    #expect(rig.transcriber.requests.count == 1)
    // At once: nobody waits out a head start for a session that never opened.
    #expect(ContinuousClock.now - began < Self.wellBeforeTheHeadStart)
  }

  @Test func aLiveSessionThatFailsHalfWayLeavesTheFileToDoIt() async throws {
    let live = FakeLiveTranscriber { _ in throw WisperError.network("the connection was lost") }
    let rig = try await Rig(heard: Self.fileWords, capture: FakeAudioCapture(stopDuration: 45), live: live)

    let began = ContinuousClock.now
    let done = try #require(await rig.dictate())

    #expect(done.rawText == Self.fileWords)
    #expect(done.timing?.path == .file)
    #expect(ContinuousClock.now - began < Self.wellBeforeTheHeadStart)
    #expect(rig.engine.phase == .idle)
  }

  @Test func aRecordingIsNeverThrownAwayOnTheLiveSidesWordAlone() async throws {
    // The live side heard nothing. The file is asked before the recording is dropped.
    let rig = try await Rig(heard: Self.fileWords, live: FakeLiveTranscriber(text: "  "))

    let done = try #require(await rig.dictate())

    #expect(done.rawText == Self.fileWords)
    #expect(done.timing?.path == .file)
  }

  @Test func silenceIsSilenceWhenTheFileAgrees() async throws {
    let rig = try await Rig(heard: "", live: FakeLiveTranscriber(text: ""))

    #expect(await rig.dictate() == nil)

    #expect(rig.engine.phase == .idle)
    #expect(rig.transcriber.requests.count == 1)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.isEmpty)
  }

  @Test func aLiveSideThatIsSlowIsOvertakenByTheFile() async throws {
    let stuck = Gate()
    let live = FakeLiveTranscriber { _ in
      await stuck.pass()
      return Transcript(text: Self.liveWords)
    }
    let rig = try await Rig(heard: Self.fileWords, live: live)

    let began = ContinuousClock.now
    let done = try #require(await rig.dictate())
    let taken = ContinuousClock.now - began

    #expect(done.rawText == Self.fileWords)
    #expect(done.timing?.path == .file)
    // The live side had its head start (1.8 s for three seconds of speech), and no more.
    #expect(taken > .milliseconds(1_700) && taken < .seconds(12), "took \(taken)")
    // The session nobody is waiting for any more is ended.
    #expect(await eventually { live.sessions.first?.isCancelled == true })
    await stuck.open()
  }

  @Test func aSessionStillBeingOpenedWhenThePersonStopsIsNotWaitedFor() async throws {
    // Opening takes for ever (a slow network). The person has already let go of the key.
    let library = InMemoryLibrary()
    let recording: any CaptureSession = ShortOfSound(seconds: 45)
    let slow = SlowToOpen()
    let take = LiveTake(transcriber: slow, library: library, capture: Task { .success(recording) })
    let pipeline = DictationPipeline(
      library: library,
      transcriber: FakeTranscriber(text: Self.fileWords),
      languageModel: echoingModel()
    )

    let began = ContinuousClock.now
    let heard = try await pipeline.heard(
      TranscriptionRequest(audio: URL(fileURLWithPath: "/nonexistent.m4a"), model: "m"),
      live: take,
      duration: 45
    )

    #expect(heard.transcript.text == Self.fileWords)
    #expect(heard.path == .file)
    // A third of a second of grace, not the 6 s head start an open session would get.
    #expect(ContinuousClock.now - began < Self.wellBeforeTheHeadStart)
    await slow.gate.open()
  }

  @Test func aLiveSideThatAnswersWhileTheFileIsOnItsWayStillWins() async throws {
    let liveHeld = Gate()
    let fileHeld = Gate()
    let live = FakeLiveTranscriber { _ in
      await liveHeld.pass()
      return Transcript(text: Self.liveWords)
    }
    let rig = try await Rig(
      transcriber: FakeTranscriber { _ in
        await fileHeld.pass()
        return Transcript(text: Self.fileWords)
      },
      live: live
    )

    rig.engine.start()
    let finishing = Task { await rig.engine.finish() }
    // The head start is over: the file has been sent as well.
    await fileHeld.arrival()
    await liveHeld.open()
    let done = try #require(await finishing.value)

    #expect(done.rawText == Self.liveWords)
    #expect(done.timing?.path == .live)
    await fileHeld.open()
  }

  @Test func whenBothFailTheRecordingIsKeptForARetry() async throws {
    let rig = try await Rig(
      transcriber: FakeTranscriber { _ in throw WisperError.noAnswer },
      live: FakeLiveTranscriber { _ in throw WisperError.network("the connection was lost") }
    )

    #expect(await rig.dictate() == nil)

    let entry = try #require(await rig.history().first)
    #expect(entry.failure == "OpenAI did not answer in time, even on a second try. Try again in a moment.")
    #expect(rig.audioFiles == [try #require(entry.audioFile)])
    #expect(entry.timing?.path == .file)
  }

  @Test func aRetryUsesTheFile() async throws {
    let offline = Shared(true)
    let live = FakeLiveTranscriber { _ in
      if offline.value { throw WisperError.network("the connection was lost") }
      return Transcript(text: Self.liveWords)
    }
    let rig = try await Rig(
      transcriber: FakeTranscriber { _ in
        if offline.value { throw WisperError.noAnswer }
        return Transcript(text: Self.fileWords)
      },
      live: live
    )
    #expect(await rig.dictate() == nil)
    offline.value = false

    let failed = try #require(await rig.history().first)
    let fixed = try #require(await rig.engine.retry(failed.id))

    // There is no sound to stream for a recording that is already over.
    #expect(fixed.rawText == Self.fileWords)
    #expect(fixed.timing?.path == .file)
    #expect(live.requests.count == 1)
  }

  @Test func soundThatNeverReachedTheSessionIsNotTrusted() async throws {
    let live = FakeLiveTranscriber(text: "only the first half")
    let recording: any CaptureSession = ShortOfSound(seconds: 2)
    let take = LiveTake(
      transcriber: live,
      library: InMemoryLibrary(),
      capture: Task { .success(recording) }
    )

    // The file is five seconds long. The session was handed two.
    #expect(await take.text(ofRecording: 5) == nil)
    #expect(live.sessions.first?.isCancelled == true)
    #expect(live.sessions.first?.isFinished == false)
  }

  @Test func soundThatAllArrivedIsTrusted() async throws {
    let live = FakeLiveTranscriber(text: "all of it")
    let recording: any CaptureSession = ShortOfSound(seconds: 5)
    let take = LiveTake(
      transcriber: live,
      library: InMemoryLibrary(),
      capture: Task { .success(recording) }
    )

    // A file is padded to a whole number of encoder blocks, so a little slack is allowed.
    #expect(await take.text(ofRecording: 5.1)?.text == "all of it")
  }

  // MARK: - Nothing leaves when it must not

  @Test(arguments: ["127.0.0.1:63570/v1", "localhost:11434"])
  func noLiveSessionIsOpenedWhileTheServerAddressCannotBeUsed(address: String) async throws {
    let live = FakeLiveTranscriber(text: "this must not leave")
    let rig = try await Rig(settings: Settings(apiBaseURL: address), live: live)

    #expect(await rig.dictate() == nil)

    #expect(live.requests.isEmpty)
    #expect(rig.transcriber.requests.isEmpty)
    #expect(failureMessage(rig.engine) == WisperError.invalidServerAddress.errorDescription)
  }

  @Test func cancellingWhileRecordingEndsTheLiveSession() async throws {
    let live = FakeLiveTranscriber(text: Self.liveWords)
    let rig = try await Rig(live: live)

    rig.engine.start()
    await rig.microphoneOpen()
    #expect(await eventually { live.sessions.count == 1 })
    rig.engine.cancel()

    #expect(await eventually { live.sessions.first?.isCancelled == true })
    #expect(live.sessions.first?.isFinished == false)
    #expect(rig.transcriber.requests.isEmpty)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.isEmpty)
  }

  @Test func cancellingWhileTheTextIsBeingMadeEndsTheLiveSession() async throws {
    let asked = Gate()
    let live = FakeLiveTranscriber { _ in
      await asked.pass()
      return Transcript(text: Self.liveWords)
    }
    let target = FakeTextTarget()
    let rig = try await Rig(live: live, target: target)

    rig.engine.start()
    let finishing = Task { await rig.engine.finish() }
    await asked.arrival()
    rig.engine.cancel()

    #expect(await finishing.value == nil)
    #expect(await eventually { live.sessions.first?.isCancelled == true })
    #expect(await target.inserted.isEmpty)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.isEmpty)
    await asked.open()
  }

  @Test func aTapTooShortToHoldSpeechEndsTheLiveSessionToo() async throws {
    let live = FakeLiveTranscriber(text: Self.liveWords)
    let rig = try await Rig(capture: FakeAudioCapture(stopDuration: 0.1), live: live)

    #expect(await rig.dictate() == nil)

    #expect(rig.engine.phase == .idle)
    #expect(await eventually { live.sessions.first?.isCancelled == true })
    #expect(live.sessions.first?.isFinished == false)
  }

  // MARK: - What has been heard so far

  @Test func showsWhatHasBeenHeardSoFarWhileRecording() async throws {
    let live = FakeLiveTranscriber(text: "Let us meet at four.")
    let rig = try await Rig(live: live)
    #expect(rig.engine.partialText.isEmpty)

    rig.engine.start()
    #expect(await eventually { live.sessions.count == 1 })
    let session = try #require(live.sessions.first)
    session.hear("Let us")
    await rig.until { $0.partialText == "Let us" }
    session.hear("Let us meet at")
    await rig.until { $0.partialText == "Let us meet at" }

    // It is a draft of the recording in progress: gone when the recording is over.
    let done = await rig.engine.finish()
    #expect(rig.engine.partialText.isEmpty)
    #expect(done?.rawText == "Let us meet at four.")
  }

  @Test func theDraftOfOneRecordingNeverShowsInTheNext() async throws {
    let live = FakeLiveTranscriber(text: Self.liveWords)
    let rig = try await Rig(live: live)

    rig.engine.start()
    #expect(await eventually { live.sessions.count == 1 })
    live.sessions[0].hear("the first")
    await rig.until { $0.partialText == "the first" }
    rig.engine.cancel()
    #expect(rig.engine.partialText.isEmpty)

    rig.engine.start()
    #expect(rig.engine.partialText.isEmpty)
    #expect(await eventually { live.sessions.count == 2 })
    // The old session speaks up late. Nobody is listening to it any more.
    live.sessions[0].hear("the first, again")
    live.sessions[1].hear("the second")
    await rig.until { $0.partialText == "the second" }
    rig.engine.cancel()
  }

  // MARK: - How long

  @Test func theHeadStartGrowsALittleWithTheRecording() {
    #expect(DictationPipeline.liveHeadStart(forRecording: 0) == 1.5)
    #expect(DictationPipeline.liveHeadStart(forRecording: 5) == 2)
    // Never long: the file is the safety net, and it should be thrown early.
    #expect(DictationPipeline.liveHeadStart(forRecording: 600) == 6)
  }
}
