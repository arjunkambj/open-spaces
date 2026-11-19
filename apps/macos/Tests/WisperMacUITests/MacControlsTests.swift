import Foundation
import Testing
import WisperDomain
import WisperEngine
import WisperMac

@testable import WisperMacUI

@MainActor
@Suite struct MacControlsTests {
  // MARK: Push to talk

  @Test func holdingPushToTalkRecordsAndReleasingTypes() async {
    let stage = await Stage()
    stage.press(.down(.pushToTalk))
    #expect(stage.recordingMode == .dictation)
    #expect(!stage.isHandsFree)
    stage.press(.up(.pushToTalk))
    #expect(await stage.typed() == ["Hello there."])
  }

  @Test func pushToTalkLooksLikeARecordingOnlyAfterAMoment() async {
    let stage = await Stage(revealDelay: .milliseconds(80))
    stage.press(.down(.pushToTalk))
    #expect(stage.model.dictation.isRecording)
    #expect(!stage.controls.showsRecording)
    await settle { stage.controls.showsRecording }
    #expect(stage.controls.showsRecording)
    stage.press(.up(.pushToTalk))
    _ = await stage.typed()
    await settle { !stage.controls.showsRecording }
    #expect(!stage.controls.showsRecording)
  }

  @Test func aKeyThatWasOnlyPassingThroughLeavesNoTrace() async {
    let stage = await Stage(revealDelay: .milliseconds(40))
    // fn, then an arrow key.
    stage.press(.down(.pushToTalk), .abandoned(.pushToTalk, replacedBy: nil))
    #expect(stage.phase == .idle)
    try? await Task.sleep(for: .milliseconds(120))
    #expect(!stage.controls.showsRecording)
    #expect(await stage.typed().isEmpty)
    // The release of a key that was given up does nothing either.
    stage.press(.up(.pushToTalk))
    #expect(stage.phase == .idle)
  }

  @Test func escapeThrowsTheRecordingAway() async {
    let stage = await Stage()
    stage.press(.down(.pushToTalk), .cancel)
    #expect(stage.phase == .idle)
    #expect(await stage.typed().isEmpty)
  }

  // MARK: Hands-free

  @Test func pushToTalkThatGrowsIntoHandsFreeStartsHandsFree() async {
    let stage = await Stage()
    // fn, then Space while fn is still down.
    stage.press(.down(.pushToTalk), .abandoned(.pushToTalk, replacedBy: .handsFree), .down(.handsFree))
    #expect(stage.isHandsFree)
    #expect(stage.controls.showsRecording)
    // Letting go of the keys does not end a hands-free recording.
    stage.press(.up(.handsFree))
    #expect(stage.isHandsFree)
  }

  @Test func theHandsFreeShortcutPressedAgainFinishes() async {
    let stage = await Stage()
    stage.press(.down(.pushToTalk), .abandoned(.pushToTalk, replacedBy: .handsFree), .down(.handsFree))
    stage.press(.up(.handsFree))
    stage.press(.down(.pushToTalk), .abandoned(.pushToTalk, replacedBy: .handsFree), .down(.handsFree))
    stage.press(.up(.handsFree))
    #expect(await stage.typed() == ["Hello there."])
    #expect(stage.phase == .idle)
  }

  @Test func pushToTalkAloneFinishesAHandsFreeRecording() async {
    let stage = await Stage()
    stage.controls.toggleHandsFree()
    #expect(stage.isHandsFree)
    stage.press(.down(.pushToTalk))
    #expect(stage.isHandsFree, "It ends when the key is let go, once we know what the press was")
    stage.press(.up(.pushToTalk))
    #expect(await stage.typed() == ["Hello there."])
  }

  @Test func aPassingKeyDoesNotEndAHandsFreeRecording() async {
    let stage = await Stage()
    stage.controls.toggleHandsFree()
    stage.press(.down(.pushToTalk), .abandoned(.pushToTalk, replacedBy: nil))
    stage.press(.up(.pushToTalk))
    #expect(stage.isHandsFree)
    stage.controls.cancel()
  }

  @Test func togglingHandsFreeTwiceTypesOnce() async {
    let stage = await Stage()
    stage.controls.toggleHandsFree()
    stage.controls.toggleHandsFree()
    stage.controls.toggleHandsFree()  // Still wrapping up: ignored.
    #expect(await stage.typed() == ["Hello there."])
  }

  // MARK: Command mode

  @Test func pushToTalkThatGrowsIntoCommandModeRecordsACommand() async {
    let stage = await Stage()
    stage.press(.down(.pushToTalk), .abandoned(.pushToTalk, replacedBy: .commandMode), .down(.commandMode))
    #expect(stage.recordingMode == .command)
    stage.press(.up(.commandMode))
    await settle { stage.phase == .idle && !stage.controls.isWrappingUp }
    #expect(stage.model.dictation.last?.mode == .command)
  }

  // MARK: The key and failures

  @Test func nothingIsRecordedWithoutAKey() async {
    let stage = await Stage(hasKey: false)
    stage.press(.down(.pushToTalk))
    #expect(stage.phase == .idle)
    #expect(stage.capture.requests.isEmpty)
    #expect(stage.controls.notice == MacControls.Notice(message: "Add your OpenAI key", fix: .settings))
    stage.controls.fixNotice()
    #expect(stage.opened.destinations == [.settings])
    #expect(stage.controls.notice == nil)
    stage.press(.up(.pushToTalk))
    #expect(stage.phase == .idle)
  }

  @Test func aServerOfYourOwnNeedsNoKey() async {
    let stage = await Stage(hasKey: false)
    stage.model.update { $0.apiBaseURL = "http://localhost:11434" }
    stage.controls.toggleHandsFree()
    #expect(stage.isHandsFree)
    stage.controls.cancel()
  }

  @Test func aFailureBecomesANoticeThatKnowsItsFix() async {
    let stage = await Stage(captureFailure: .permissionDenied(.microphone))
    stage.controls.toggleHandsFree()
    await settle { stage.controls.notice != nil }
    #expect(stage.controls.notice?.fix == .permission(.microphone))
    #expect(!stage.controls.showsRecording)
    stage.controls.dismissNotice()
    #expect(stage.controls.notice == nil)
    #expect(stage.phase == .idle)
  }

  @Test func noticesGoAwayByThemselves() async {
    let stage = await Stage(hasKey: false, noticeTime: .milliseconds(40))
    stage.controls.toggleHandsFree()
    #expect(stage.controls.notice != nil)
    await settle { stage.controls.notice == nil }
    #expect(stage.controls.notice == nil)
  }

  @Test func fixesAreToldFromTheMessage() {
    #expect(MacControls.fix(for: WisperError.missingAPIKey.localizedDescription) == .settings)
    #expect(MacControls.fix(for: WisperError.invalidAPIKey.localizedDescription) == .settings)
    let insert = WisperError.permissionDenied(.accessibility).localizedDescription
    #expect(
      MacControls.fix(for: insert + " Your text is saved in your history.") == .permission(.accessibility)
    )
    #expect(MacControls.fix(for: WisperError.noSpeech.localizedDescription) == nil)
  }

  // MARK: Meetings, paste and the pill

  @Test func theMeetingShortcutStartsAndStopsARecording() async {
    let stage = await Stage()
    stage.press(.down(.toggleMeeting), .up(.toggleMeeting))
    await settle { stage.model.meetings.isRecording }
    #expect(stage.model.meetings.isRecording)
    stage.press(.down(.toggleMeeting), .up(.toggleMeeting))
    await settle { !stage.model.meetings.isRecording }
    #expect(!stage.model.meetings.isRecording)
  }

  @Test func pasteLastTypesTheNewestDictationAgain() async {
    let stage = await Stage()
    stage.press(.down(.pasteLast), .up(.pasteLast))
    var typed: [String] = []
    for _ in 0..<400 where typed.isEmpty {
      try? await Task.sleep(for: .milliseconds(5))
      typed = await stage.target.inserted
    }
    #expect(typed.count == 1)
    #expect(typed.first == stage.model.dictations.first { !$0.failed }?.text)
  }

  @Test func thePillCanBeHiddenForAWhileAndBroughtBack() async {
    let stage = await Stage()
    stage.controls.hidePill(for: .seconds(3600))
    #expect((stage.controls.pillHiddenUntil ?? .distantPast) > Date().addingTimeInterval(3500))
    stage.controls.hidePill(for: nil)
    #expect(stage.controls.pillHiddenUntil == nil)
    stage.controls.hidePill(for: .milliseconds(30))
    await settle { stage.controls.pillHiddenUntil == nil }
    #expect(stage.controls.pillHiddenUntil == nil)
  }
}
