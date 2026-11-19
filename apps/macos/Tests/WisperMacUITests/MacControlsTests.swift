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

  // MARK: A held key that grows into a longer shortcut

  @Test func holdingThenSpaceKeepsWhatWasSaidSoFar() async {
    let stage = await Stage()
    stage.press(.down(.pushToTalk))
    await settle { stage.capture.sessions.count == 1 }
    await settle { stage.controls.showsRecording }
    // The person talks with fn held, then taps Space to go on hands-free.
    stage.press(.abandoned(.pushToTalk, replacedBy: .handsFree), .down(.handsFree), .up(.handsFree))
    #expect(stage.isHandsFree)
    try? await Task.sleep(for: .milliseconds(60))
    #expect(stage.capture.sessions.count == 1, "The microphone is not closed and opened again")
    #expect(stage.capture.sessions.first?.isEnded == false)
    #expect(stage.count(.start) == 1, "One recording, one start sound")
    stage.controls.toggleHandsFree()
    #expect(await stage.typed() == ["Hello there."])
    #expect(stage.capture.requests.count == 1)
  }

  @Test func growingBeforeTheRecordingShowedPlaysTheStartSoundOnce() async {
    let stage = await Stage(revealDelay: .seconds(5))
    // fn + Space in one quick move: the recording had not shown or sounded yet.
    stage.press(.down(.pushToTalk), .abandoned(.pushToTalk, replacedBy: .handsFree), .down(.handsFree))
    #expect(stage.controls.showsRecording)
    #expect(stage.isHandsFree)
    #expect(stage.heard.sounds == [.start])
    stage.controls.cancel()
  }

  @Test func growingIntoCommandModeKeepsTheMicrophoneOpen() async {
    let stage = await Stage()
    stage.press(.down(.pushToTalk))
    await settle { stage.capture.sessions.count == 1 }
    stage.press(.abandoned(.pushToTalk, replacedBy: .commandMode), .down(.commandMode))
    #expect(stage.recordingMode == .command)
    #expect(!stage.isHandsFree)
    stage.press(.up(.commandMode))
    await settle { stage.phase == .idle && !stage.controls.isWrappingUp }
    #expect(stage.capture.sessions.count == 1)
    #expect(stage.model.dictation.last?.mode == .command)
  }

  @Test func growingIntoSomethingElseLeavesNothingBehind() async {
    let stage = await Stage()
    stage.press(.down(.pushToTalk))
    await settle { stage.controls.showsRecording }
    // A shortcut of the person's own making: push to talk plus a key pastes the last one.
    stage.press(.abandoned(.pushToTalk, replacedBy: .pasteLast))
    #expect(stage.phase == .idle)
    #expect(!stage.controls.showsRecording)
    // The next dictation is a new one: it starts with its sound like any other.
    stage.press(.down(.pushToTalk))
    await settle { stage.controls.showsRecording }
    #expect(stage.count(.start) == 2)
    stage.controls.cancel()
  }

  // MARK: A press while the last dictation is still being written

  @Test func aKeyHeldWhileTheLastOneIsWrittenStartsAsSoonAsItCan() async {
    let stage = await Stage(transcribeDelay: .milliseconds(250))
    stage.press(.down(.pushToTalk))
    await settle { stage.capture.sessions.count == 1 }
    stage.press(.up(.pushToTalk))
    await settle { stage.isWriting }
    // The next sentence: the key goes down at once and stays down.
    stage.press(.down(.pushToTalk))
    #expect(stage.capture.sessions.count == 1, "Not yet: the first is still being written")
    await settle { stage.capture.sessions.count == 2 }
    #expect(stage.capture.sessions.count == 2, "The press was remembered")
    #expect(stage.recordingMode == .dictation)
    stage.press(.up(.pushToTalk))
    #expect(await stage.typed() == ["Hello there.", "Hello there."])
  }

  @Test func aKeyLetGoBeforeTheLastOneIsWrittenIsDroppedQuietly() async {
    let stage = await Stage(transcribeDelay: .milliseconds(200))
    stage.press(.down(.pushToTalk))
    await settle { stage.capture.sessions.count == 1 }
    stage.press(.up(.pushToTalk))
    await settle { stage.isWriting }
    stage.press(.down(.pushToTalk), .up(.pushToTalk))
    #expect(await stage.typed() == ["Hello there."])
    try? await Task.sleep(for: .milliseconds(60))
    #expect(stage.phase == .idle)
    #expect(stage.capture.sessions.count == 1)
    #expect(stage.controls.notice == nil)
    #expect(stage.count(.error) == 0)
  }

  @Test func aLongWaitSaysWhyNothingIsRecordedYet() async {
    let stage = await Stage(transcribeDelay: .milliseconds(400))
    stage.controls.busyNoticeDelay = .milliseconds(30)
    stage.press(.down(.pushToTalk))
    await settle { stage.capture.sessions.count == 1 }
    stage.press(.up(.pushToTalk))
    await settle { stage.isWriting }
    stage.press(.down(.pushToTalk))
    await settle { stage.controls.notice != nil }
    #expect(stage.controls.notice?.message == "Still writing the last one. Not listening yet.")
    #expect(stage.count(.error) == 1)
    // Once the key can record, the notice has done its job.
    await settle { stage.capture.sessions.count == 2 }
    #expect(stage.controls.notice == nil)
    stage.controls.cancel()
  }

  @Test func aTapThenAHoldRecordsTheHold() async {
    let stage = await Stage()
    // A tap by mistake, then the key again, held, while the tap's microphone is still closing.
    stage.press(.down(.pushToTalk), .up(.pushToTalk), .down(.pushToTalk))
    await settle { stage.capture.sessions.count == 2 }
    #expect(stage.capture.sessions.count == 2, "The second press was not taken for an end")
    await settle { stage.model.dictation.isRecording && !stage.controls.isWrappingUp }
    #expect(stage.recordingMode == .dictation)
    stage.press(.up(.pushToTalk))
    #expect(await stage.typed().count == 2)
  }

  @Test func theHandsFreeShortcutSaysSoWhenItCannotStartYet() async {
    let stage = await Stage(transcribeDelay: .milliseconds(200))
    stage.controls.toggleHandsFree()
    await settle { stage.capture.sessions.count == 1 }
    stage.controls.toggleHandsFree()
    await settle { stage.isWriting }
    stage.controls.toggleHandsFree()
    #expect(stage.controls.notice?.message == "Still writing the last one. Try again in a moment.")
    #expect(stage.count(.error) == 1)
    #expect(await stage.typed() == ["Hello there."])
  }

  // MARK: Escape

  @Test func escapeWhileTextIsBeingWrittenChangesNothing() async {
    let stage = await Stage(transcribeDelay: .milliseconds(150))
    stage.press(.down(.pushToTalk))
    await settle { stage.capture.sessions.count == 1 }
    stage.press(.up(.pushToTalk))
    await settle { stage.isWriting }
    stage.press(.cancel)
    #expect(stage.isWriting)
    #expect(await stage.typed() == ["Hello there."])
  }

  @Test func escapeIsOnlyTakenFromOtherAppsWhileRecording() async throws {
    let stage = await Stage(transcribeDelay: .milliseconds(150), withMonitor: true)
    let monitor = try #require(stage.monitor)
    #expect(!monitor.cancelsOnEscape)
    stage.controls.toggleHandsFree()
    await settle { monitor.cancelsOnEscape }
    #expect(monitor.cancelsOnEscape, "A hands-free recording has no held key: Escape must reach us")
    stage.controls.toggleHandsFree()
    #expect(!monitor.cancelsOnEscape, "From the moment it ends, Escape belongs to the app in front")
    await settle { stage.isWriting }
    try? await Task.sleep(for: .milliseconds(30))
    #expect(!monitor.cancelsOnEscape)
    #expect(await stage.typed() == ["Hello there."])
    #expect(!monitor.cancelsOnEscape)
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

  @Test func fixesAreToldFromTheMessage() throws {
    #expect(MacControls.fix(for: WisperError.missingAPIKey.localizedDescription) == .settings)
    #expect(MacControls.fix(for: WisperError.invalidAPIKey.localizedDescription) == .settings)
    let insert = WisperError.permissionDenied(.accessibility).localizedDescription
    #expect(
      MacControls.fix(for: insert + " Your text is saved in your history.") == .permission(.accessibility)
    )
    #expect(MacControls.fix(for: WisperError.noSpeech.localizedDescription) == nil)
    #expect(MacControls.fix(for: WisperError.rateLimited.localizedDescription) == nil)
    // A custom server's messages, and a bad address, lead to Settings too.
    let server = try APIServer(address: "https://llm.example.com/v1")
    #expect(MacControls.fix(for: WisperError.missingAPIKey.message(server: server)) == .settings)
    #expect(MacControls.fix(for: WisperError.network("timed out").message(server: server)) == .settings)
    #expect(MacControls.fix(for: WisperError.invalidServerAddress.localizedDescription) == .settings)
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

  @Test func aMeetingStartedByALinkAlwaysPlaysTheStartSound() async {
    let stage = await Stage()
    stage.model.update { $0.playSounds = false }
    stage.controls.startMeeting(title: "Standup")
    await settle { stage.model.meetings.isRecording && !stage.heard.sounds.isEmpty }
    #expect(stage.model.meetings.live?.title == "Standup")
    #expect(stage.heard.sounds == [.start], "Sounds are off, but this recording was started from outside")
    // A second link while one is running does nothing.
    stage.controls.startMeeting(title: "Another")
    try? await Task.sleep(for: .milliseconds(40))
    #expect(stage.model.meetings.live?.title == "Standup")
    #expect(stage.heard.sounds == [.start])
    await stage.model.meetings.stop()
  }

  // MARK: Open at login and the clipboard

  @Test func theOpenAtLoginSettingFollowsWhatTheMacDid() {
    #expect(MacControls.launchAtLoginSetting(for: .on, wanted: true) == true)
    #expect(MacControls.launchAtLoginSetting(for: .on, wanted: nil) == true)
    #expect(MacControls.launchAtLoginSetting(for: .off, wanted: true) == false)
    #expect(MacControls.launchAtLoginSetting(for: .off, wanted: nil) == false)
    #expect(MacControls.launchAtLoginSetting(for: .needsApproval, wanted: true) == nil)
    #expect(MacControls.launchAtLoginSetting(for: .unavailable, wanted: true) == false)
    #expect(MacControls.launchAtLoginSetting(for: .unavailable, wanted: nil) == nil)
    #expect(MacControls.launchAtLoginSetting(for: .unavailable, wanted: false) == nil)
  }

  @Test func aRefusalToOpenAtLoginTakesTheSettingBackAndSaysSo() async {
    let stage = await Stage()
    stage.model.update { $0.launchAtLogin = true }
    stage.controls.noteLaunchAtLogin(.off, wanted: true)
    #expect(stage.controls.notice?.fix == .loginItems)
    await settle { !stage.model.settings.launchAtLogin }
    #expect(!stage.model.settings.launchAtLogin)
  }

  @Test func waitingForApprovalKeepsTheSettingAndPointsAtLoginItems() async {
    let stage = await Stage()
    stage.model.update { $0.launchAtLogin = true }
    stage.controls.noteLaunchAtLogin(.needsApproval, wanted: true)
    #expect(
      stage.controls.notice
        == MacControls.Notice(
          message: "Allow Open Wisper in Login Items so it can open at login.",
          fix: .loginItems
        )
    )
    try? await Task.sleep(for: .milliseconds(40))
    #expect(stage.model.settings.launchAtLogin)
  }

  @Test func checkingAtLaunchCorrectsTheSettingWithoutANotice() async {
    let stage = await Stage()
    stage.model.update { $0.launchAtLogin = true }
    // The person took the app out of Login Items in System Settings.
    stage.controls.noteLaunchAtLogin(.off)
    await settle { !stage.model.settings.launchAtLogin }
    #expect(!stage.model.settings.launchAtLogin)
    #expect(stage.controls.notice == nil)
  }

  @Test func copiedTextIsNewsNotAProblem() async {
    let stage = await Stage()
    stage.controls.noteCopied()
    #expect(
      stage.controls.notice == MacControls.Notice(message: "Copied to the clipboard", isProblem: false)
    )
    #expect(stage.heard.sounds.isEmpty)
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
