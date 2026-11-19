import Foundation
import Testing
import WisperDomain
import WisperEngine

@testable import WisperPhone

@MainActor
@Suite struct PhoneDictationTests {
  @Test func tapSpeakTapPutsTheTextOnTheClipboard() async {
    let rig = await Rig()

    await rig.dictation.toggle()
    #expect(rig.dictation.isRecording)
    #expect(rig.dictation.result == nil)

    await rig.dictation.toggle()
    #expect(!rig.dictation.isRecording)
    #expect(rig.dictation.result?.text == "Call the dentist tomorrow morning.")
    #expect(rig.copied.texts == ["Call the dentist tomorrow morning."])
    #expect(rig.dictation.copies == 1)
    #expect(rig.dictation.problem == nil)
  }

  @Test func theResultIsInTheLibraryForTheKeyboardToFind() async throws {
    let rig = await Rig()
    await rig.dictation.toggle()
    await rig.dictation.toggle()

    let stored = try await rig.library.dictations()
    #expect(stored.first?.text == "Call the dentist tomorrow morning.")
  }

  @Test func withoutAKeyNothingIsRecorded() async {
    let rig = await Rig(key: nil)

    #expect(rig.dictation.problem == .missingKey)
    await rig.dictation.toggle()
    #expect(!rig.dictation.isRecording)
    #expect(rig.capture.requests.isEmpty)
  }

  @Test func aServerOfYourOwnNeedsNoKey() async {
    let rig = await Rig(
      key: nil,
      settings: Settings(onboardedAt: Date(), apiBaseURL: "http://localhost:11434")
    )

    #expect(rig.dictation.problem == nil)
    await rig.dictation.toggle()
    #expect(rig.dictation.isRecording)
    rig.dictation.cancel()
  }

  @Test func asksForTheMicrophoneTheFirstTime() async {
    let rig = await Rig(microphone: .notDetermined, answer: .granted)

    await rig.dictation.toggle()
    #expect(rig.permissions.requests == 1)
    #expect(rig.dictation.isRecording)
    rig.dictation.cancel()
  }

  @Test func aNoToTheMicrophoneIsExplainedNotRetried() async {
    let rig = await Rig(microphone: .notDetermined, answer: .denied)

    await rig.dictation.toggle()
    #expect(!rig.dictation.isRecording)
    #expect(rig.dictation.problem == .microphoneDenied)

    // Later taps do not ask again: only the Settings app can change the answer.
    await rig.dictation.toggle()
    #expect(rig.permissions.requests == 1)
    #expect(rig.capture.requests.isEmpty)
  }

  @Test func comingBackFromSettingsClearsTheMicrophoneNotice() async {
    let rig = await Rig(microphone: .denied)
    #expect(rig.dictation.problem == .microphoneDenied)

    rig.permissions.microphone = .granted
    rig.dictation.refresh()
    #expect(rig.dictation.problem == nil)
  }

  @Test func silenceIsSaidPlainly() async {
    let rig = await Rig(transcriber: FakeTranscriber(text: "  "))

    await rig.dictation.toggle()
    await rig.dictation.toggle()
    #expect(rig.dictation.problem == .nothingHeard)
    #expect(rig.dictation.result == nil)
    #expect(rig.copied.texts.isEmpty)

    rig.dictation.dismissProblem()
    #expect(rig.dictation.problem == nil)
  }

  @Test func aFailureCanBeTriedAgain() async {
    let transcriber = FlakyTranscriber()
    let rig = await Rig(transcriber: transcriber)

    await rig.dictation.toggle()
    await rig.dictation.toggle()
    #expect(rig.dictation.result == nil)
    // The failed entry reaches the screen's copy of the library a moment later.
    let offered = await eventually {
      if case .failed(_, .some) = rig.dictation.problem { return true }
      return false
    }
    #expect(offered)

    transcriber.heal()
    await rig.dictation.retry()
    #expect(rig.dictation.result?.text == "Call the dentist tomorrow morning.")
    #expect(rig.copied.last == "Call the dentist tomorrow morning.")
    #expect(rig.dictation.problem == nil)
  }

  @Test func cancelThrowsTheRecordingAway() async {
    let rig = await Rig()

    await rig.dictation.toggle()
    rig.dictation.cancel()
    #expect(!rig.dictation.isRecording)
    #expect(rig.dictation.problem == nil)
    #expect(rig.copied.texts.isEmpty)
  }

  @Test func holdingTheButtonIsPushToTalk() async {
    let rig = await Rig()

    rig.dictation.holdBegan()
    guard case .recording(_, _, let handsFree) = rig.dictation.phase else {
      Issue.record("Holding did not start a recording.")
      return
    }
    #expect(!handsFree)

    await rig.dictation.holdEnded()
    #expect(rig.dictation.result?.text == "Call the dentist tomorrow morning.")
  }

  @Test func lettingGoAfterATapStartedDoesNothing() async {
    let rig = await Rig()

    await rig.dictation.toggle()
    // A long press on the button while it is already recording is not a hold.
    rig.dictation.holdBegan()
    await rig.dictation.holdEnded()
    #expect(rig.dictation.isRecording)
    rig.dictation.cancel()
  }

  @Test func aHoldNeverAsksForTheMicrophone() async {
    let rig = await Rig(microphone: .notDetermined)

    rig.dictation.holdBegan()
    #expect(!rig.dictation.isRecording)
    #expect(rig.permissions.requests == 0)
  }

  @Test func theReleaseOfAHoldAndTheTapItCausesFinishOnce() async {
    let rig = await Rig()

    rig.dictation.holdBegan()
    // Lifting the finger ends the hold and also counts as a tap on the button.
    async let released: Void = rig.dictation.holdEnded()
    async let tapped: Void = rig.dictation.toggle()
    _ = await (released, tapped)

    #expect(!rig.dictation.isRecording)
    #expect(rig.dictation.problem == nil)
    #expect(rig.copied.texts.count == 1)
  }

  @Test func noDictationWhileAMeetingIsRecorded() async throws {
    let rig = await Rig()
    try await rig.model.meetings.start()

    await rig.dictation.toggle()
    #expect(!rig.dictation.isRecording)
    guard case .failed(let message, nil) = rig.dictation.problem else {
      Issue.record("Expected a notice about the meeting.")
      return
    }
    #expect(message.contains("meeting"))
    await rig.model.meetings.stop()
  }

  @Test func copyAndEdit() async throws {
    let rig = await Rig()
    await rig.dictation.toggle()
    await rig.dictation.toggle()
    let result = try #require(rig.dictation.result)

    rig.dictation.copy(result)
    #expect(rig.copied.texts.count == 2)

    await rig.dictation.save("  Call the dentist on Friday.  ", for: result)
    #expect(rig.dictation.result?.text == "Call the dentist on Friday.")
    #expect(rig.copied.last == "Call the dentist on Friday.")
    let stored = try await rig.library.dictations()
    #expect(stored.first { $0.id == result.id }?.text == "Call the dentist on Friday.")
    #expect(rig.dictation.copies == 3)

    // Saving the same text, or nothing, changes nothing.
    await rig.dictation.save("Call the dentist on Friday.", for: try #require(rig.dictation.result))
    await rig.dictation.save("   ", for: result)
    #expect(rig.dictation.copies == 3)
  }

  @Test func earlierLeavesOutFailuresAndTheResultOnShow() async {
    let old = Dictation(
      createdAt: Date().addingTimeInterval(-600),
      rawText: "old",
      text: "An older note.",
      duration: 2
    )
    let broken = Dictation(
      createdAt: Date().addingTimeInterval(-300),
      rawText: "",
      text: "",
      duration: 2,
      failure: "offline"
    )
    let rig = await Rig(dictations: [old, broken])
    #expect(rig.dictation.earlier.map(\.text) == ["An older note."])

    await rig.dictation.toggle()
    await rig.dictation.toggle()
    let settled = await eventually { rig.model.dictations.count == 3 }
    #expect(settled)
    #expect(rig.dictation.earlier.map(\.text) == ["An older note."])
  }
}
