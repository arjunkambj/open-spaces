import Foundation
import Testing
import WisperDomain
import WisperEngine

/// A transcriber that fails while `offline` is true and hears `text` otherwise.
private func transcriber(offline: Shared<Bool>, hears text: String) -> FakeTranscriber {
  FakeTranscriber { _ in
    if offline.value { throw WisperError.network("offline") }
    return Transcript(text: text)
  }
}

private let offlineMessage = WisperError.network("offline").errorDescription ?? ""
private let accessMessage = WisperError.permissionDenied(.accessibility).errorDescription ?? ""

@MainActor
@Suite("Dictation: failures, retry, paste last and kept audio", .timeLimit(.minutes(1)))
struct DictationRecoveryTests {
  // MARK: - The microphone cannot open

  @Test func aMicrophoneThatCannotOpenShowsWhy() async throws {
    let rig = try await Rig(capture: FakeAudioCapture(failure: .permissionDenied(.microphone)))
    rig.engine.start()
    #expect(rig.engine.isRecording)
    await rig.until { !$0.isRecording }
    #expect(
      rig.engine.phase == .failed(message: "Microphone access is needed. Turn it on in System Settings.")
    )
    #expect(rig.engine.isBusy)

    // Letting go of the key afterwards changes nothing.
    #expect(await rig.engine.finish() == nil)
    #expect(failureMessage(rig.engine) != nil)
    #expect(await rig.history().isEmpty)

    rig.engine.dismissFailure()
    #expect(rig.engine.phase == .idle)
  }

  @Test func aQuickTapWithNoMicrophoneAccessShowsWhyToo() async throws {
    let rig = try await Rig(capture: FakeAudioCapture(failure: .captureFailed("the device is in use")))
    #expect(await rig.dictate() == nil)
    #expect(rig.engine.phase == .failed(message: "Recording failed: the device is in use"))
    #expect(rig.transcriber.requests.isEmpty)
  }

  @Test func startClearsAFailure() async throws {
    let rig = try await Rig(target: FakeTextTarget(failure: .permissionDenied(.accessibility)))
    await rig.dictate()
    #expect(failureMessage(rig.engine) != nil)
    rig.engine.start()
    #expect(rig.engine.isRecording)
    await rig.microphoneOpen()
    rig.engine.cancel()
    #expect(rig.engine.phase == .idle)
  }

  @Test func cancelLeavesAFailureOnScreen() async throws {
    let rig = try await Rig(target: FakeTextTarget(failure: .permissionDenied(.accessibility)))
    await rig.dictate()
    let failed = rig.engine.phase
    rig.engine.cancel()
    #expect(rig.engine.phase == failed)
    rig.engine.dismissFailure()
    #expect(rig.engine.phase == .idle)
    rig.engine.dismissFailure()
    #expect(rig.engine.phase == .idle)
  }

  // MARK: - Transcription fails

  @Test(arguments: [true, false])
  func aFailedTranscriptionKeepsTheAudioAndCanBeRetried(keepAudio: Bool) async throws {
    let offline = Shared(true)
    let target = FakeTextTarget(context: DictationContext(appName: "Mail", bundleID: "com.apple.mail"))
    let rig = try await Rig(
      settings: Settings(keepDictationAudio: keepAudio),
      transcriber: transcriber(offline: offline, hears: "The build is green again."),
      target: target
    )
    #expect(await rig.dictate() == nil)
    #expect(rig.engine.phase == .failed(message: offlineMessage))
    #expect(rig.engine.last == nil)
    #expect(await target.inserted.isEmpty)

    // A failed entry holds the audio whatever the "keep audio" setting says.
    let failed = try #require(await rig.history().first)
    #expect(await rig.history().count == 1)
    #expect(failed.failed)
    #expect(failed.failure == offlineMessage)
    #expect(failed.text.isEmpty)
    #expect(failed.duration == 3)
    #expect(failed.appName == "Mail")
    #expect(failed.bundleID == "com.apple.mail")
    let audio = try #require(failed.audioFile)
    #expect(rig.audioFiles == [audio])

    // Still offline: the entry stays failed and keeps its audio.
    #expect(await rig.engine.retry(failed.id) == nil)
    #expect(rig.engine.phase == .failed(message: offlineMessage))
    #expect(await rig.history().first?.failed == true)
    #expect(rig.audioFiles == [audio])

    offline.value = false
    let fixed = try #require(await rig.engine.retry(failed.id))
    #expect(rig.engine.phase == .idle)
    #expect(fixed.id == failed.id)
    #expect(fixed.createdAt == failed.createdAt)
    #expect(fixed.failure == nil)
    #expect(fixed.text == "The build is green again.")
    #expect(fixed.rawText == "The build is green again.")
    #expect(fixed.duration == 3)
    #expect(fixed.appName == "Mail")
    #expect(await target.inserted == ["The build is green again."])
    #expect(await rig.history() == [fixed])
    #expect(rig.engine.last == fixed)
    #expect(fixed.audioFile == (keepAudio ? audio : nil))
    #expect(rig.audioFiles == (keepAudio ? [audio] : []))
    #expect(rig.transcriber.requests.map(\.audio.lastPathComponent) == [audio, audio, audio])
  }

  @Test func aCommandWhoseModelCallFailsCanBeRetried() async throws {
    let down = Shared(true)
    let target = FakeTextTarget(selection: "teh cat")
    let rig = try await Rig(
      heard: "fix the typo",
      model: FakeLanguageModel { _ in
        if down.value { throw WisperError.server(status: 500, message: "try later") }
        return "the cat"
      },
      target: target
    )
    #expect(await rig.dictate(.command) == nil)
    let failed = try #require(await rig.history().first)
    #expect(failed.failure == "OpenAI returned an error (500): try later")
    #expect(failed.mode == .command)
    // The instruction was heard, so it is kept on the entry.
    #expect(failed.rawText == "fix the typo")
    #expect(failed.text.isEmpty)
    #expect(rig.audioFiles.count == 1)

    down.value = false
    let fixed = try #require(await rig.engine.retry(failed.id))
    #expect(fixed.mode == .command)
    #expect(fixed.text == "the cat")
    #expect(await target.inserted == ["the cat"])
    #expect(await rig.history() == [fixed])
  }

  @Test func aCommandWithAnEmptyReplyFails() async throws {
    let target = FakeTextTarget(selection: "hello")
    let rig = try await Rig(heard: "make it better", model: FakeLanguageModel(text: " "), target: target)
    #expect(await rig.dictate(.command) == nil)
    #expect(failureMessage(rig.engine)?.contains("empty") == true)
    #expect(await target.inserted.isEmpty)
    #expect(await rig.history().first?.failed == true)
  }

  @Test func retryShowsItsOwnModeWhileItWorks() async throws {
    let listening = Gate()
    let failed = Dictation(
      mode: .command,
      rawText: "",
      text: "",
      duration: 4,
      audioFile: "kept.m4a",
      failure: "x"
    )
    let rig = try await Rig(
      dictations: [failed],
      transcriber: FakeTranscriber { _ in
        await listening.pass()
        return Transcript(text: "write a title")
      },
      model: FakeLanguageModel(text: "A Title")
    )
    try Data("audio".utf8).write(to: rig.audioFolder.appendingPathComponent("kept.m4a"))

    let retrying = Task { await rig.engine.retry(failed.id) }
    await listening.arrival()
    #expect(rig.engine.phase == .processing(mode: .command))
    // Nothing else may start meanwhile.
    rig.engine.start()
    #expect(rig.engine.phase == .processing(mode: .command))
    #expect(await rig.engine.retry(failed.id) == nil)
    await listening.open()
    #expect(await retrying.value?.text == "A Title")
    #expect(rig.transcriber.requests.count == 1)
  }

  @Test func cancellingARetryKeepsTheFailedEntryAndItsAudio() async throws {
    let listening = Gate()
    let target = FakeTextTarget()
    let failed = Dictation(rawText: "", text: "", duration: 4, audioFile: "kept.m4a", failure: "offline")
    let rig = try await Rig(
      dictations: [failed],
      transcriber: FakeTranscriber { _ in
        await listening.pass()
        return Transcript(text: "hello again")
      },
      target: target
    )
    try Data("audio".utf8).write(to: rig.audioFolder.appendingPathComponent("kept.m4a"))

    let retrying = Task { await rig.engine.retry(failed.id) }
    await listening.arrival()
    rig.engine.cancel()
    #expect(rig.engine.phase == .idle)
    await listening.open()

    #expect(await retrying.value == nil)
    #expect(await target.inserted.isEmpty)
    #expect(await rig.history() == [failed])
    #expect(rig.audioFiles == ["kept.m4a"])
  }

  @Test func retryExplainsWhatItCannotDo() async throws {
    let done = Dictation(rawText: "hi", text: "Hi", duration: 2)
    let noAudio = Dictation(rawText: "", text: "", duration: 2, failure: "offline")
    let lostAudio = Dictation(rawText: "", text: "", duration: 2, audioFile: "gone.m4a", failure: "offline")
    let target = FakeTextTarget()
    let rig = try await Rig(dictations: [done, noAudio, lostAudio], target: target)

    #expect(await rig.engine.retry(UUID()) == nil)
    #expect(rig.engine.phase == .failed(message: "That dictation was not found."))

    for id in [noAudio.id, lostAudio.id] {
      #expect(await rig.engine.retry(id) == nil)
      #expect(rig.engine.phase == .failed(message: "The recording of that dictation was not found."))
    }

    // A dictation that already worked is left alone.
    #expect(await rig.engine.retry(done.id) == nil)
    #expect(rig.engine.phase == .idle)

    #expect(rig.transcriber.requests.isEmpty)
    #expect(await target.inserted.isEmpty)
    #expect(await rig.history().count == 3)
  }

  @Test func retryOnlyReadsAudioFromTheDictationFolder() async throws {
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-wisper-outside-\(UUID().uuidString).m4a")
    try Data("not ours".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    let failed = Dictation(rawText: "", text: "", duration: 2, audioFile: outside.path, failure: "offline")
    let rig = try await Rig(dictations: [failed])
    #expect(await rig.engine.retry(failed.id) == nil)
    #expect(rig.engine.phase == .failed(message: "The recording of that dictation was not found."))
    #expect(rig.transcriber.requests.isEmpty)
  }

  @Test func aRetryThatHearsNothingSaysSo() async throws {
    let failed = Dictation(rawText: "", text: "", duration: 4, audioFile: "kept.m4a", failure: "offline")
    let rig = try await Rig(heard: "", dictations: [failed])
    try Data("audio".utf8).write(to: rig.audioFolder.appendingPathComponent("kept.m4a"))
    #expect(await rig.engine.retry(failed.id) == nil)
    #expect(rig.engine.phase == .failed(message: "No speech was heard."))
    let entry = try #require(await rig.history().first)
    #expect(entry.failure == "No speech was heard.")
    #expect(rig.audioFiles == ["kept.m4a"])
  }

  // MARK: - The text cannot be inserted

  @Test func textThatCannotBeInsertedIsKeptInHistory() async throws {
    let target = ScriptedTarget(failure: .permissionDenied(.accessibility))
    let rig = try await Rig(heard: "The words must survive this.", target: target)
    #expect(await rig.dictate() == nil)
    #expect(rig.engine.phase == .failed(message: "\(accessMessage) Your text is saved in your history."))

    // A normal entry, not a failed one.
    let saved = try #require(await rig.history().first)
    #expect(await rig.history().count == 1)
    #expect(saved.failure == nil)
    #expect(saved.text == "The words must survive this.")
    #expect(rig.engine.last == saved)

    // Once access is given, "paste last" delivers it and clears the failure.
    await target.fail(with: nil)
    await rig.engine.pasteLast()
    #expect(await target.inserted == ["The words must survive this."])
    #expect(rig.engine.phase == .idle)
  }

  // MARK: - Paste last

  @Test func pasteLastInsertsTheNewestDictationThatWorked() async throws {
    let now = Date()
    let target = FakeTextTarget()
    let rig = try await Rig(
      dictations: [
        Dictation(createdAt: now.addingTimeInterval(-300), rawText: "old", text: "Old one", duration: 2),
        Dictation(createdAt: now.addingTimeInterval(-60), rawText: "new", text: "Newest one", duration: 2),
        Dictation(createdAt: now, rawText: "", text: "", duration: 2, audioFile: "a.m4a", failure: "offline"),
      ],
      target: target
    )
    await rig.engine.pasteLast()
    await rig.engine.pasteLast()
    #expect(await target.inserted == ["Newest one", "Newest one"])
    #expect(rig.engine.phase == .idle)
    // Pasting is not a new dictation.
    #expect(await rig.history().count == 3)
    #expect(rig.engine.last == nil)

    await rig.dictate()
    await rig.engine.pasteLast()
    #expect(await target.inserted == ["Newest one", "Newest one", "Hello world", "Hello world"])
  }

  @Test func pasteLastWithNoHistorySaysSo() async throws {
    let target = FakeTextTarget()
    let rig = try await Rig(
      dictations: [Dictation(rawText: "", text: "", duration: 2, failure: "offline")],
      target: target
    )
    await rig.engine.pasteLast()
    #expect(rig.engine.phase == .failed(message: "There is no dictation to paste yet."))
    #expect(await target.inserted.isEmpty)
  }

  @Test func pasteLastThatCannotInsertShowsWhy() async throws {
    let rig = try await Rig(
      dictations: [Dictation(rawText: "hi", text: "Hi", duration: 2)],
      target: FakeTextTarget(failure: .permissionDenied(.accessibility))
    )
    await rig.engine.pasteLast()
    #expect(rig.engine.phase == .failed(message: accessMessage))
  }

  @Test func pasteLastIsIgnoredWhileRecording() async throws {
    let target = FakeTextTarget()
    let rig = try await Rig(dictations: [Dictation(rawText: "hi", text: "Hi", duration: 2)], target: target)
    rig.engine.start()
    await rig.engine.pasteLast()
    #expect(rig.engine.isRecording)
    #expect(await target.inserted.isEmpty)
    await rig.microphoneOpen()
    rig.engine.cancel()
  }

  // MARK: - Kept audio

  @Test func keptAudioGetsAFileOfItsOwnPerDictation() async throws {
    let rig = try await Rig(settings: Settings(keepDictationAudio: true))
    let first = try #require(await rig.dictate())
    let second = try #require(await rig.dictate())
    #expect(first.audioFile == "\(first.id.uuidString).m4a")
    #expect(second.audioFile == "\(second.id.uuidString).m4a")
    #expect(rig.audioFiles == [first.audioFile, second.audioFile].compactMap { $0 }.sorted())
    #expect(await rig.history().compactMap(\.audioFile).count == 2)
  }

  @Test func audioIsDeletedWhenItIsNotToBeKept() async throws {
    let rig = try await Rig(settings: Settings(keepDictationAudio: false))
    let done = try #require(await rig.dictate())
    #expect(done.audioFile == nil)
    #expect(await rig.history().first?.audioFile == nil)
    #expect(rig.audioFiles.isEmpty)
  }

  // MARK: - History turned off

  @Test func withHistoryOffNothingStaysOnDiskButPasteLastStillWorks() async throws {
    let target = FakeTextTarget()
    let rig = try await Rig(
      settings: Settings(keepDictationAudio: true, historyRetention: .never),
      target: target
    )
    let done = try #require(await rig.dictate())
    #expect(done.audioFile == nil)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.isEmpty)
    #expect(rig.engine.last == done)

    await rig.engine.pasteLast()
    #expect(await target.inserted == ["Hello world", "Hello world"])
  }

  @Test func withHistoryOffAFailureKeepsNoAudio() async throws {
    let rig = try await Rig(
      settings: Settings(historyRetention: .never),
      transcriber: FakeTranscriber { _ in throw WisperError.rateLimited }
    )
    #expect(await rig.dictate() == nil)
    #expect(failureMessage(rig.engine) == WisperError.rateLimited.errorDescription)
    #expect(await rig.history().isEmpty)
    #expect(rig.audioFiles.isEmpty)
  }

  @Test func withHistoryOffTextThatCannotBeInsertedCanBePastedLater() async throws {
    let target = ScriptedTarget(failure: .permissionDenied(.accessibility))
    let rig = try await Rig(settings: Settings(historyRetention: .never), target: target)
    #expect(await rig.dictate() == nil)
    #expect(
      rig.engine.phase
        == .failed(
          message: "\(accessMessage) Your text is not lost: use Paste last transcript to try again."
        )
    )
    await target.fail(with: nil)
    await rig.engine.pasteLast()
    #expect(await target.inserted == ["Hello world"])
    #expect(rig.engine.phase == .idle)
  }
}
