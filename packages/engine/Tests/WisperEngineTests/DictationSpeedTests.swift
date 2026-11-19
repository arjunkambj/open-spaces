import Foundation
import Testing
import WisperDomain
import WisperStore

@testable import WisperEngine

@MainActor
@Suite("Dictation: getting ready early, and how long each step took", .timeLimit(.minutes(1)))
struct DictationSpeedTests {
  // MARK: - Getting ready while the person speaks

  @Test func theConnectionIsMadeReadyTheMomentRecordingStarts() async throws {
    // The microphone is still opening: getting ready does not wait for it.
    let rig = try await Rig(captureGate: Gate())

    rig.engine.start()

    #expect(await eventually { rig.transcriber.preparations == 1 })
    #expect(rig.transcriber.requests.isEmpty)
    await rig.slowCapture?.gate.open()
    await rig.microphoneOpen()
    rig.engine.cancel()
  }

  @Test func nothingIsMadeReadyWhileTheServerAddressCannotBeUsed() async throws {
    let rig = try await Rig(settings: Settings(apiBaseURL: "localhost:11434"))

    #expect(await rig.dictate() == nil)

    #expect(rig.transcriber.preparations == 0)
    #expect(rig.transcriber.requests.isEmpty)
  }

  @Test func aRetryGetsTheConnectionReadyToo() async throws {
    let offline = Shared(true)
    let rig = try await Rig(
      transcriber: FakeTranscriber { _ in
        if offline.value { throw WisperError.noAnswer }
        return Transcript(text: "back again")
      }
    )
    #expect(await rig.dictate() == nil)
    let before = rig.transcriber.preparations
    offline.value = false

    let failed = try #require(await rig.history().first)
    #expect(await rig.engine.retry(failed.id)?.text == "Back again")
    #expect(await eventually { rig.transcriber.preparations == before + 1 })
  }

  @Test func theAppModelPassesGettingReadyThroughItsAddressCheck() async throws {
    let transcriber = FakeTranscriber(text: "hello")
    let library = InMemoryLibrary()
    let checked = AddressChecked(library: library, transcriber: transcriber, languageModel: echoingModel())

    await checked.prepare()
    #expect(transcriber.preparations == 1)

    await library.updateSettings { $0.apiBaseURL = "not an address" }
    await checked.prepare()
    #expect(transcriber.preparations == 1)
  }

  // MARK: - What a time-out says

  @Test func aServerThatDoesNotAnswerIsReportedInPlainWordsAndKeptForARetry() async throws {
    let rig = try await Rig(transcriber: FakeTranscriber { _ in throw WisperError.noAnswer })

    #expect(await rig.dictate() == nil)

    let message = "OpenAI did not answer in time, even on a second try. Try again in a moment."
    #expect(rig.engine.phase == .failed(message: message))
    let entry = try #require(await rig.history().first)
    #expect(entry.failure == message)
    #expect(rig.audioFiles == [try #require(entry.audioFile)])
  }

  // MARK: - Timings

  @Test func aFinishedDictationSaysHowLongEachStepTook() async throws {
    let rig = try await Rig(
      transcriber: FakeTranscriber { _ in
        try await Task.sleep(for: .milliseconds(40))
        return Transcript(text: "um the words that were said out loud")
      },
      model: FakeLanguageModel { _ in
        try await Task.sleep(for: .milliseconds(30))
        return "The words that were said out loud."
      }
    )

    let done = try #require(await rig.dictate())

    let timing = try #require(done.timing)
    #expect(timing.path == .file)
    #expect(try #require(timing.captureMs) >= 0)
    #expect(try #require(timing.transcribeMs) >= 40)
    #expect(try #require(timing.cleanUpMs) >= 30)
    #expect(try #require(timing.insertMs) >= 0)
    let steps = [timing.captureMs, timing.transcribeMs, timing.cleanUpMs, timing.insertMs].compactMap { $0 }
    #expect(try #require(timing.totalMs) >= steps.reduce(0, +))
    // What is saved is what was returned.
    #expect(await rig.history().first?.timing == timing)
  }

  @Test func aStepThatDidNotHappenHasNoTime() async throws {
    // Two words are not sent for tidying.
    let rig = try await Rig(heard: "hello world")

    let timing = try #require(await rig.dictate()?.timing)

    #expect(timing.cleanUpMs == nil)
    #expect(timing.transcribeMs != nil)
    #expect(rig.model.requests.isEmpty)
  }

  @Test func aFailedDictationSaysHowLongItTookToFail() async throws {
    let rig = try await Rig(
      transcriber: FakeTranscriber { _ in
        try await Task.sleep(for: .milliseconds(40))
        throw WisperError.noAnswer
      }
    )

    #expect(await rig.dictate() == nil)

    let timing = try #require(await rig.history().first?.timing)
    #expect(try #require(timing.transcribeMs) >= 40)
    #expect(timing.insertMs == nil)
    #expect(timing.cleanUpMs == nil)
  }

  @Test func aRetryIsTimedFromTheRetry() async throws {
    let offline = Shared(true)
    let rig = try await Rig(
      transcriber: FakeTranscriber { _ in
        if offline.value { throw WisperError.noAnswer }
        return Transcript(text: "back again")
      }
    )
    #expect(await rig.dictate() == nil)
    offline.value = false
    let failed = try #require(await rig.history().first)

    let timing = try #require(await rig.engine.retry(failed.id)?.timing)

    // There was no recording to finish this time.
    #expect(timing.captureMs == nil)
    #expect(timing.transcribeMs != nil)
    #expect(try #require(timing.totalMs) < 5_000)
  }

  @Test func timingsAreStoredInTheHistoryFileAsNumbersOnly() async throws {
    let folder = TemporaryFolder()
    let library = FileLibrary(root: folder.url)
    let engine = DictationEngine(
      library: library,
      capture: FakeAudioCapture(),
      transcriber: FakeTranscriber(text: "a secret thing was said here"),
      languageModel: echoingModel(),
      target: FakeTextTarget()
    )
    engine.start()
    #expect(await engine.finish() != nil)

    let file = folder.url.appendingPathComponent("dictations.json")
    let entries = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
    )
    let timing = try #require(entries.first?["timing"] as? [String: Any])
    #expect(timing["path"] as? String == "file")
    for (key, value) in timing where key != "path" { #expect(value is NSNumber, "\(key)") }
    #expect(
      Set(timing.keys).isSubset(of: ["path", "captureMs", "transcribeMs", "cleanUpMs", "insertMs", "totalMs"])
    )
    // And they come back the same.
    #expect(try await FileLibrary(root: folder.url).dictations().first?.timing?.path == .file)
  }

  // MARK: - Not waiting long for polish

  @Test func aShortDictationWaitsLessForTidyingThanALongOne() {
    let few = "let us meet at four"
    let many = Array(repeating: "word", count: 240).joined(separator: " ")

    #expect(DictationPipeline.cleanUpTime(for: few, limit: 12, openAI: true) < 6)
    #expect(DictationPipeline.cleanUpTime(for: many, limit: 12, openAI: true) == 12)
    // The limit the app sets is never exceeded.
    #expect(DictationPipeline.cleanUpTime(for: few, limit: 0.05, openAI: true) == 0.05)
    #expect(DictationPipeline.cleanUpTime(for: many, limit: 3, openAI: true) == 3)
    // A server of the person's own may be a slow one: it keeps the whole limit.
    #expect(DictationPipeline.cleanUpTime(for: few, limit: 12, openAI: false) == 12)
  }
}
