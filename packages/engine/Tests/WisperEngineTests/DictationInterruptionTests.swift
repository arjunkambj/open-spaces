import Foundation
import Testing
import WisperDomain
import WisperEngine
import WisperStore

/// A transcriber that waits at `gate` before it answers.
private func slowTranscriber(_ gate: Gate, hears text: String) -> FakeTranscriber {
  FakeTranscriber { _ in
    await gate.pass()
    return Transcript(text: text)
  }
}

@MainActor
private func engine(
  on library: any Library,
  transcriber: FakeTranscriber,
  target: any TextTarget = FakeTextTarget()
) -> DictationEngine {
  DictationEngine(
    library: library,
    capture: FakeAudioCapture(),
    transcriber: transcriber,
    languageModel: echoingModel(),
    target: target
  )
}

@MainActor
@Suite("Dictation: a quit in the middle, on the real file library", .timeLimit(.minutes(1)))
struct DictationInterruptionTests {
  @Test func aQuitWhileTextIsBeingMadeLeavesADictationThatCanBeTriedAgain() async throws {
    let folder = TemporaryFolder()
    let library = FileLibrary(root: folder.url)
    let listening = Gate()
    let target = FakeTextTarget(context: DictationContext(appName: "Mail", bundleID: "com.apple.mail"))
    let first = engine(
      on: library,
      transcriber: slowTranscriber(listening, hears: "never arrives"),
      target: target
    )

    first.start()
    let finishing = Task { await first.finish() }
    await listening.arrival()

    // "Quit" now: this is what the next launch finds.
    let left = try folder.snapshot()
    let relaunched = FileLibrary(root: left.url)
    let entry = try #require(try await relaunched.dictations().first)
    #expect(try await relaunched.dictations().count == 1)
    #expect(entry.failed)
    #expect(entry.failure == "Open Wisper closed before this dictation was finished. Try it again.")
    #expect(entry.text.isEmpty)
    #expect(entry.duration == 3)
    #expect(entry.appName == "Mail")
    #expect(left.audioFiles == [try #require(entry.audioFile)])

    // The next launch tidies up, which must leave this recording alone, and can run it again.
    let again = FakeTextTarget()
    let second = engine(
      on: relaunched,
      transcriber: FakeTranscriber(text: "The words came back."),
      target: again
    )
    await second.recoverUnfinished()
    #expect(left.audioFiles == [try #require(entry.audioFile)])
    let fixed = try #require(await second.retry(entry.id))
    #expect(fixed.id == entry.id)
    #expect(fixed.text == "The words came back.")
    #expect(fixed.failure == nil)
    #expect(await again.inserted == ["The words came back."])
    #expect(try await relaunched.dictations() == [fixed])

    // Without the quit, the real entry takes the place of the first one: same id, no failure.
    await listening.open()
    let done = try #require(await finishing.value)
    #expect(done.id == entry.id)
    #expect(done.failure == nil)
    #expect(try await FileLibrary(root: folder.url).dictations() == [done])
    #expect(folder.audioFiles == [try #require(done.audioFile)])
  }

  @Test func withHistoryOffAQuitLeavesNothingAfterTheNextLaunch() async throws {
    let folder = TemporaryFolder()
    let library = FileLibrary(root: folder.url)
    try await library.updateSettings { $0.historyRetention = .never }
    let listening = Gate()
    let first = engine(on: library, transcriber: slowTranscriber(listening, hears: "never arrives"))

    first.start()
    let finishing = Task { await first.finish() }
    await listening.arrival()

    // Nothing about the dictation is written down, so only the recording itself is there.
    let left = try folder.snapshot()
    let relaunched = FileLibrary(root: left.url)
    #expect(try await relaunched.dictations().isEmpty)
    #expect(left.audioFiles.count == 1)

    // The next launch removes it, however soon it comes.
    await engine(on: relaunched, transcriber: FakeTranscriber(text: "x")).recoverUnfinished()
    #expect(left.audioFiles.isEmpty)
    #expect(try await relaunched.dictations().isEmpty)

    // Without the quit, nothing stays either.
    await listening.open()
    #expect(await finishing.value != nil)
    #expect(folder.audioFiles.isEmpty)
    #expect(try await FileLibrary(root: folder.url).dictations().isEmpty)
  }

  @Test func theTidyUpAtLaunchRemovesOnlyRecordingsNothingPointsAt() async throws {
    let folder = TemporaryFolder()
    let library = FileLibrary(root: folder.url)
    let audio = try await library.dictationAudioDirectory()
    for name in [
      "kept.m4a", "failed.m4a", "\(UUID().uuidString).m4a", "microphone-0000.m4a", "microphone-0000.wav",
    ] {
      try Data("audio".utf8).write(to: audio.appendingPathComponent(name))
    }
    try await library.save(Dictation(rawText: "hi", text: "Hi", duration: 2, audioFile: "kept.m4a"))
    try await library.save(
      Dictation(rawText: "", text: "", duration: 2, audioFile: "failed.m4a", failure: "offline")
    )

    let engine = engine(on: library, transcriber: FakeTranscriber(text: "x"))
    await engine.recoverUnfinished()

    #expect(folder.audioFiles == ["failed.m4a", "kept.m4a"])
    #expect(try await library.dictations().count == 2)

    // A recording made afterwards is not touched by a second call.
    engine.start()
    let done = try #require(await engine.finish())
    await engine.recoverUnfinished()
    #expect(folder.audioFiles == ["failed.m4a", "kept.m4a", try #require(done.audioFile)].sorted())
  }

  @Test func theTidyUpDoesNothingWhileADictationIsUnderWay() async throws {
    let folder = TemporaryFolder()
    let library = FileLibrary(root: folder.url)
    try await library.updateSettings { $0.historyRetention = .never }
    let listening = Gate()
    let engine = engine(on: library, transcriber: slowTranscriber(listening, hears: "still here"))

    engine.start()
    let finishing = Task { await engine.finish() }
    await listening.arrival()
    // The recording being worked on has no history entry (history is off). It must survive.
    #expect(folder.audioFiles.count == 1)
    await engine.recoverUnfinished()
    #expect(folder.audioFiles.count == 1)

    await listening.open()
    #expect(await finishing.value?.text == "Still here")
  }

  @Test func aCancelledDictationLeavesNoEntryAndNoAudio() async throws {
    let folder = TemporaryFolder()
    let library = FileLibrary(root: folder.url)
    let listening = Gate()
    let engine = engine(on: library, transcriber: slowTranscriber(listening, hears: "thrown away"))

    engine.start()
    let finishing = Task { await engine.finish() }
    await listening.arrival()
    #expect(try await library.dictations().count == 1)
    engine.cancel()
    await listening.open()

    #expect(await finishing.value == nil)
    #expect(try await library.dictations().isEmpty)
    #expect(folder.audioFiles.isEmpty)
  }

  @Test func silenceLeavesNoEntryAndNoAudio() async throws {
    let folder = TemporaryFolder()
    let library = FileLibrary(root: folder.url)
    let engine = engine(on: library, transcriber: FakeTranscriber(text: "  "))

    engine.start()
    #expect(await engine.finish() == nil)

    #expect(engine.phase == .idle)
    #expect(try await library.dictations().isEmpty)
    #expect(folder.audioFiles.isEmpty)
  }
}

@MainActor
@Suite("Dictation: saving fails, commands, limits and wording", .timeLimit(.minutes(1)))
struct DictationSafetyTests {
  // MARK: - Saving fails

  @Test func aFailedSaveKeepsTheRecording() async throws {
    let target = ScriptedTarget(failure: .permissionDenied(.accessibility))
    let wrapped = Shared<ScriptedLibrary?>(nil)
    let rig = try await Rig(heard: "The only copy of these words.", target: target) { inner in
      let library = ScriptedLibrary(inner)
      wrapped.value = library
      return library
    }
    // The entry written before the slow work is stored; the finished one is refused.
    await wrapped.value?.failDictationSaves { $0 >= 2 }

    #expect(await rig.dictate() == nil)

    // Inserting failed and saving failed: the recording is what is left of the words on disk.
    #expect(failureMessage(rig.engine)?.contains("Your text is not lost") == true)
    let entry = try #require(await rig.history().first)
    #expect(entry.failed)
    #expect(rig.audioFiles == [try #require(entry.audioFile)])
    // In this session the text is still at hand.
    #expect(rig.engine.last?.text == "The only copy of these words.")
    await target.fail(with: nil)
    await rig.engine.pasteLast()
    #expect(await target.inserted == ["The only copy of these words."])

    // Once saving works again, the entry can be run again.
    await wrapped.value?.failDictationSaves { _ in false }
    let fixed = try #require(await rig.engine.retry(entry.id, insert: false))
    #expect(fixed.text == "The only copy of these words.")
    #expect(await rig.history() == [fixed])
  }

  @Test func aRecordingIsNotDeletedWhenNothingCanBeSavedAtAll() async throws {
    let wrapped = Shared<ScriptedLibrary?>(nil)
    let rig = try await Rig(heard: "Nothing can be written down.") { inner in
      let library = ScriptedLibrary(inner)
      wrapped.value = library
      return library
    }
    await wrapped.value?.failDictationSaves { _ in true }

    #expect(await rig.dictate() == nil)

    #expect(failureMessage(rig.engine) == ScriptedLibrary.refusal.errorDescription)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.count == 1)
    #expect(rig.engine.last?.text == "Nothing can be written down.")
  }

  @Test func withHistoryOffAFailedSaveStillKeepsNothing() async throws {
    let wrapped = Shared<ScriptedLibrary?>(nil)
    let rig = try await Rig(settings: Settings(historyRetention: .never)) { inner in
      let library = ScriptedLibrary(inner)
      wrapped.value = library
      return library
    }
    await wrapped.value?.failDictationSaves { _ in true }

    #expect(await rig.dictate() == nil)
    #expect(rig.audioFiles.isEmpty)
    #expect(await rig.history().isEmpty)
  }

  // MARK: - Commands tried again

  @Test func retryingAFailedCommandChangesTheTextThatWasSelectedThen() async throws {
    let down = Shared(true)
    let target = ScriptedTarget(selection: " A long paragraph that says very little. ")
    let rig = try await Rig(
      heard: "make this shorter",
      model: FakeLanguageModel { _ in
        if down.value { throw WisperError.server(status: 500, message: "try later") }
        return "Short."
      },
      target: target
    )
    #expect(await rig.dictate(.command) == nil)
    let failed = try #require(await rig.history().first)
    #expect(failed.mode == .command)
    #expect(failed.selection == " A long paragraph that says very little. ")

    // By the time of the retry the person is somewhere else: nothing is selected.
    await target.select(nil)
    down.value = false
    let fixed = try #require(await rig.engine.retry(failed.id))

    #expect(fixed.text == " Short. ")
    #expect(await target.inserted == [" Short. "])
    // The model was asked to change the old selection, not to write something new.
    let asked = try #require(rig.model.requests.last)
    #expect(asked.user.contains("A long paragraph that says very little."))
    #expect(asked.user == rig.model.requests.first?.user)
    #expect(asked.system == rig.model.requests.first?.system)
    // A finished entry has no use for the selection any more.
    #expect(fixed.selection == nil)
    #expect(await rig.history() == [fixed])
  }

  @Test func aFailedCommandWithNothingSelectedStillWritesNewTextOnRetry() async throws {
    let down = Shared(true)
    let target = ScriptedTarget(selection: nil)
    let rig = try await Rig(
      heard: "write a title for the launch post",
      model: FakeLanguageModel { _ in
        if down.value { throw WisperError.rateLimited }
        return "Launch Day"
      },
      target: target
    )
    #expect(await rig.dictate(.command) == nil)
    let failed = try #require(await rig.history().first)
    #expect(failed.selection == "")

    // Something happens to be selected now. It was not what the command was for.
    await target.select("unrelated text")
    down.value = false
    let fixed = try #require(await rig.engine.retry(failed.id))

    #expect(fixed.text == "Launch Day")
    #expect(rig.model.requests.last?.user.contains("unrelated text") == false)
    #expect(rig.model.requests.last?.user == rig.model.requests.first?.user)
  }

  @Test func aFailedCommandWhoseSelectionWasNotKeptIsNotMadeUpOnRetry() async throws {
    // An entry from before selections were kept.
    let failed = Dictation(
      mode: .command,
      rawText: "make this shorter",
      text: "",
      duration: 4,
      audioFile: "kept.m4a",
      failure: "OpenAI returned an error (500): try later"
    )
    let target = FakeTextTarget(selection: nil)
    let rig = try await Rig(
      heard: "make this shorter",
      dictations: [failed],
      model: FakeLanguageModel(text: "An invented text about nothing."),
      target: target
    )
    try Data("audio".utf8).write(to: rig.audioFolder.appendingPathComponent("kept.m4a"))

    #expect(await rig.engine.retry(failed.id) == nil)

    #expect(
      rig.engine.phase
        == .failed(
          message: "This command cannot be tried again, because the text it was for was not kept. "
            + "Select the text and say the command again."
        )
    )
    #expect(await target.inserted.isEmpty)
    #expect(rig.transcriber.requests.isEmpty)
    #expect(rig.model.requests.isEmpty)
    // The entry and its recording are left as they were.
    #expect(await rig.history() == [failed])
    #expect(rig.audioFiles == ["kept.m4a"])
  }

  @Test func aCommandKeepsItsSelectionAcrossAQuit() async throws {
    let folder = TemporaryFolder()
    let library = FileLibrary(root: folder.url)
    let listening = Gate()
    let first = DictationEngine(
      library: library,
      capture: FakeAudioCapture(),
      transcriber: FakeTranscriber { _ in
        await listening.pass()
        return Transcript(text: "fix the typo")
      },
      languageModel: FakeLanguageModel(text: "the cat"),
      target: FakeTextTarget(selection: "teh cat")
    )
    first.start(mode: .command)
    let finishing = Task { await first.finish() }
    await listening.arrival()

    let left = try folder.snapshot()
    let relaunched = FileLibrary(root: left.url)
    let entry = try #require(try await relaunched.dictations().first)
    #expect(entry.mode == .command)
    #expect(entry.selection == "teh cat")
    let target = FakeTextTarget(selection: nil)
    let second = DictationEngine(
      library: relaunched,
      capture: FakeAudioCapture(),
      transcriber: FakeTranscriber(text: "fix the typo"),
      languageModel: FakeLanguageModel(text: "the cat"),
      target: target
    )
    #expect(await second.retry(entry.id)?.text == "the cat")

    await listening.open()
    let done = try #require(await finishing.value)
    #expect(done.selection == nil)
    #expect(try await library.dictations() == [done])
  }

  // MARK: - A reply that is far too long

  @Test func aCommandReplyThatIsAWallOfTextIsNotTyped() async throws {
    let wall = String(repeating: "All work and no play. ", count: 400)
    let target = FakeTextTarget(selection: "teh cat")
    let rig = try await Rig(heard: "fix the typo", model: FakeLanguageModel(text: wall), target: target)

    #expect(await rig.dictate(.command) == nil)

    #expect(
      rig.engine.phase
        == .failed(
          message: "The reply was far longer than expected, so it was not typed. Try the command again."
        )
    )
    #expect(await target.inserted.isEmpty)
    let failed = try #require(await rig.history().first)
    #expect(failed.failed)
    #expect(failed.text.isEmpty)
    // Kept like any other failed command, so it can be tried again.
    #expect(failed.selection == "teh cat")
    #expect(rig.audioFiles.count == 1)
  }

  @Test func aLongAnswerToALongSelectionIsStillTyped() async throws {
    let selection = String(repeating: "A sentence worth keeping. ", count: 400)
    let longer = String(repeating: "A sentence worth keeping, with more detail. ", count: 400)
    let target = FakeTextTarget(selection: selection)
    let rig = try await Rig(heard: "add more detail", model: FakeLanguageModel(text: longer), target: target)

    let done = try #require(await rig.dictate(.command))

    #expect(done.text.count > 10_000)
    #expect(await target.inserted.count == 1)

    // Writing something new has room too.
    let essay = String(repeating: "word ", count: 700)
    let writer = try await Rig(heard: "write a short essay", model: FakeLanguageModel(text: essay))
    #expect(await writer.dictate(.command)?.text.count == essay.count - 1)
  }

  // MARK: - A slow clean-up

  @Test func aCleanUpThatTakesTooLongIsNotWaitedFor() async throws {
    let stuck = Gate()
    let target = FakeTextTarget()
    let rig = try await Rig(
      heard: "the raw words are good enough",
      // Never answers, and does not stop when asked either.
      model: FakeLanguageModel { _ in
        await stuck.pass()
        return "Too late."
      },
      target: target
    )
    #expect(rig.engine.cleanUpLimit == 12)
    rig.engine.cleanUpLimit = 0.05

    let began = ContinuousClock.now
    let done = try #require(await rig.dictate())

    #expect(ContinuousClock.now - began < .seconds(5))
    #expect(done.text == "The raw words are good enough")
    #expect(done.rawText == "the raw words are good enough")
    #expect(await target.inserted == ["The raw words are good enough"])
    #expect(rig.model.requests.count == 1)
    await stuck.open()
  }

  @Test func aCleanUpThatAnswersInTimeIsUsed() async throws {
    let rig = try await Rig(
      heard: "um the clean words are better",
      model: FakeLanguageModel(text: "The clean words are better.")
    )
    rig.engine.cleanUpLimit = 30
    #expect(await rig.dictate()?.text == "The clean words are better.")
  }

  @Test func aCommandIsNotCutShortByTheCleanUpLimit() async throws {
    let rig = try await Rig(
      heard: "write a title",
      model: FakeLanguageModel { _ in
        try await Task.sleep(for: .milliseconds(150))
        return "A Title"
      }
    )
    rig.engine.cleanUpLimit = 0.01
    #expect(await rig.dictate(.command)?.text == "A Title")
  }

  // MARK: - A server of the person's own

  @Test func errorsNameTheCustomServerAndNotOpenAI() async throws {
    let rig = try await Rig(
      settings: Settings(apiBaseURL: "http://127.0.0.1:8080/v1"),
      transcriber: FakeTranscriber { _ in throw WisperError.network("the server did not answer") }
    )

    #expect(await rig.dictate() == nil)

    let message = try #require(failureMessage(rig.engine))
    #expect(
      message
        == "Could not reach 127.0.0.1. Check that the server is running and the address in Settings is right."
        + " (the server did not answer)"
    )
    #expect(!message.contains("OpenAI"))
    #expect(!message.localizedCaseInsensitiveContains("internet connection"))
    #expect(await rig.history().first?.failure == message)
  }

  @Test func errorsForOpenAIReadAsBefore() async throws {
    let rig = try await Rig(
      transcriber: FakeTranscriber { _ in throw WisperError.network("you are offline") }
    )
    #expect(await rig.dictate() == nil)
    #expect(
      rig.engine.phase
        == .failed(message: "Could not reach OpenAI. Check your internet connection. (you are offline)")
    )
  }

  @Test(arguments: ["127.0.0.1:63570/v1", "localhost:11434", "ftp://example.com/v1"])
  func aServerAddressThatCannotBeUsedIsAnErrorAndNothingIsSent(address: String) async throws {
    let target = FakeTextTarget()
    let rig = try await Rig(
      heard: "this must not leave",
      settings: Settings(apiBaseURL: address),
      target: target
    )

    #expect(await rig.dictate() == nil)

    #expect(
      rig.engine.phase
        == .failed(message: "The custom server address in Settings is not a valid web address.")
    )
    #expect(rig.transcriber.requests.isEmpty)
    #expect(rig.model.requests.isEmpty)
    #expect(await target.inserted.isEmpty)

    // The words are not lost: once the address is put right, the dictation can be run again.
    let failed = try #require(await rig.history().first)
    #expect(failed.failed)
    await rig.library.updateSettings { $0.apiBaseURL = "http://127.0.0.1:63570/v1" }
    #expect(await rig.engine.retry(failed.id)?.rawText == "this must not leave")
    #expect(rig.transcriber.requests.count == 1)
  }
}
