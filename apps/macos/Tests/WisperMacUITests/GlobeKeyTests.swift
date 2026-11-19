import Foundation
import Testing
import WisperDomain
import WisperEngine
import WisperMac

@testable import WisperMacUI

/// The fn (Globe) key: the one-time question on the pill, the fix behind it and the hint in the screens.
@MainActor
@Suite struct GlobeKeyControlsTests {
  private func stage(value: Int?, outcome: GlobeKey.Outcome = .now) async -> (Stage, FakeGlobeSystem) {
    let system = FakeGlobeSystem(value: value, outcome: outcome)
    let stage = await Stage(globeKey: GlobeKeySetting(system: system.system))
    return (stage, system)
  }

  /// One push-to-talk dictation from start to typed text.
  private func dictate(_ stage: Stage) async {
    stage.press(.down(.pushToTalk), .up(.pushToTalk))
    _ = await stage.typed()
  }

  @Test func theQuestionComesOnceAfterADictation() async {
    let (stage, system) = await stage(value: 2)
    #expect(stage.controls.notice == nil, "Not at launch, out of nowhere")
    await dictate(stage)
    await settle { stage.controls.notice != nil }
    let notice = stage.controls.notice
    #expect(notice?.fix == .globeKey)
    #expect(notice?.answers == MacControls.Notice.Answers(yes: "Fix it", no: "Not now"))
    #expect(notice?.isProblem == false)
    #expect(notice?.message.contains("emoji picker") == true)
    #expect(system.writes.isEmpty, "Asking changes nothing")

    // "Not now": gone, nothing changed, and never asked again.
    stage.controls.dismissNotice()
    #expect(stage.controls.notice == nil)
    await dictate(stage)
    try? await Task.sleep(for: .milliseconds(60))
    #expect(stage.controls.notice == nil)
    #expect(system.writes.isEmpty)
    #expect(stage.controls.globeKey.needsFix(for: stage.model.settings.shortcuts), "Settings still offers it")
  }

  @Test func fixItSetsTheKeyToDoNothingAndSaysSo() async {
    let (stage, system) = await stage(value: 2)
    await dictate(stage)
    await settle { stage.controls.notice != nil }
    stage.controls.fixNotice()
    #expect(system.writes == [0])
    #expect(stage.controls.notice?.message == "Done. macOS now leaves the fn key to Open Wisper.")
    #expect(stage.controls.notice?.isProblem == false)
    #expect(stage.controls.notice?.answers == nil)
    #expect(stage.controls.globeKey.previousUse == .showEmoji)
    #expect(!stage.controls.globeKey.needsFix(for: stage.model.settings.shortcuts))
  }

  @Test func itIsHonestWhenTheChangeNeedsALogOut() async {
    let (stage, system) = await stage(value: 2, outcome: .afterLogin)
    stage.controls.fixGlobeKey()
    #expect(system.writes == [0])
    #expect(stage.controls.notice?.message.contains("log out") == true)
  }

  @Test func itPointsAtKeyboardSettingsWhenMacOSRefuses() async {
    let (stage, system) = await stage(value: 2, outcome: .failed)
    stage.controls.fixGlobeKey()
    #expect(system.writes == [0])
    #expect(stage.controls.notice?.fix == .keyboardSettings)
    #expect(stage.controls.notice?.isProblem == true)
  }

  @Test func noQuestionWhenMacOSLeavesTheKeyAlone() async {
    let (stage, system) = await stage(value: 0)
    await dictate(stage)
    try? await Task.sleep(for: .milliseconds(60))
    #expect(stage.controls.notice == nil)
    #expect(system.writes.isEmpty)
  }

  @Test func noQuestionWhenFnIsNotPartOfAShortcut() async {
    let (stage, system) = await stage(value: 2)
    stage.model.update { settings in
      for action in ShortcutAction.allCases { settings.shortcuts[action] = KeyCombo() }
      settings.shortcuts[.pushToTalk] = KeyCombo(modifiers: [.option])
    }
    await settle { !GlobeKey.isUsed(by: stage.model.settings.shortcuts) }
    await dictate(stage)
    try? await Task.sleep(for: .milliseconds(60))
    #expect(stage.controls.notice == nil)
    #expect(system.writes.isEmpty)
  }

  @Test func aKeyThatWasOnlyPassingThroughBringsNoQuestion() async {
    let (stage, _) = await stage(value: 2)
    // fn, then an arrow key.
    stage.press(.down(.pushToTalk), .abandoned(.pushToTalk, replacedBy: nil))
    try? await Task.sleep(for: .milliseconds(60))
    #expect(stage.controls.notice == nil)
    #expect(stage.controls.globeKey.shouldAsk(for: stage.model.settings.shortcuts), "Still to be asked")
  }

  @Test func theQuestionNeverCoversAnotherMessage() async {
    let (stage, _) = await stage(value: 2)
    stage.press(.down(.pushToTalk))
    stage.controls.noteCopied()
    stage.press(.up(.pushToTalk))
    _ = await stage.typed()
    try? await Task.sleep(for: .milliseconds(60))
    #expect(stage.controls.notice?.message == "Copied to the clipboard")
    #expect(stage.controls.globeKey.shouldAsk(for: stage.model.settings.shortcuts), "It waits for next time")
  }

  @Test func theQuestionGoesAwayByItselfAndStaysAway() async {
    let system = FakeGlobeSystem(value: 2)
    let stage = await Stage(globeKey: GlobeKeySetting(system: system.system))
    stage.controls.questionTime = .milliseconds(40)
    await dictate(stage)
    await settle { stage.controls.notice != nil }
    #expect(stage.controls.notice?.answers != nil)
    await settle { stage.controls.notice == nil }
    #expect(stage.controls.notice == nil)
    #expect(system.writes.isEmpty)
    #expect(!stage.controls.globeKey.shouldAsk(for: stage.model.settings.shortcuts))
  }

  @Test(arguments: [
    (GlobeKey.SystemUse.nothing, true), (.showEmoji, true), (.systemDefault, true),
    (.changeInputSource, false), (.startDictation, false),
  ])
  func theGlobeKeyPressIsHeldBackUnlessThePersonChoseAnActionForIt(use: GlobeKey.SystemUse, holdsBack: Bool) {
    #expect(MacControls.holdsBackGlobeKey(WisperDomain.Settings.defaultShortcuts, use) == holdsBack)
    // Never when fn is not ours.
    #expect(!MacControls.holdsBackGlobeKey([.pushToTalk: KeyCombo(modifiers: [.option])], use))
    #expect(!MacControls.holdsBackGlobeKey([:], use))
  }

  @Test func theWordsFitWhatMacOSDoes() {
    #expect(MacControls.globeKeyQuestion(for: .showEmoji).contains("emoji picker"))
    #expect(MacControls.globeKeyQuestion(for: .systemDefault).contains("emoji picker"))
    #expect(MacControls.globeKeyQuestion(for: .changeInputSource).contains("keyboard language"))
    #expect(MacControls.globeKeyQuestion(for: .startDictation).contains("dictation"))
    #expect(MacControls.globeKeyFixTitle(for: .showEmoji) == "Stop macOS opening the emoji picker")
  }

  // MARK: The hint in Settings and in first-run setup

  @Test func theHintFollowsTheSetting() {
    let shortcuts = WisperDomain.Settings.defaultShortcuts
    let system = FakeGlobeSystem(value: 2)
    let setting = GlobeKeySetting(system: system.system)
    #expect(GlobeKeyHint.stage(of: setting, shortcuts: shortcuts) == .conflict(.showEmoji))
    #expect(
      GlobeKeyHint.stage(of: setting, shortcuts: [.pushToTalk: KeyCombo(modifiers: [.option])]) == .nothing
    )
    setting.fix()
    #expect(GlobeKeyHint.stage(of: setting, shortcuts: shortcuts) == .nothing, "It goes away by itself")
    #expect(GlobeKeyUndoNote.text(before: .showEmoji).contains("“Show Emoji & Symbols”"))
  }

  @Test func theHintGoesAwayWhenThePersonFixesItInSystemSettings() {
    let system = FakeGlobeSystem(value: 1)
    let setting = GlobeKeySetting(system: system.system)
    let shortcuts = WisperDomain.Settings.defaultShortcuts
    #expect(GlobeKeyHint.stage(of: setting, shortcuts: shortcuts) == .conflict(.changeInputSource))
    system.value = 0
    setting.refresh()
    #expect(GlobeKeyHint.stage(of: setting, shortcuts: shortcuts) == .nothing)
    #expect(system.writes.isEmpty)
    #expect(setting.previousUse == nil, "Open Wisper changed nothing, so there is nothing to undo")
  }

  @Test func theHintSaysWhatIsStillNeeded() {
    let shortcuts = WisperDomain.Settings.defaultShortcuts
    let later = GlobeKeySetting(system: FakeGlobeSystem(value: 2, outcome: .afterLogin).system)
    later.fix()
    #expect(GlobeKeyHint.stage(of: later, shortcuts: shortcuts) == .afterLogin)
    let refused = GlobeKeySetting(system: FakeGlobeSystem(value: 2, outcome: .failed).system)
    refused.fix()
    #expect(GlobeKeyHint.stage(of: refused, shortcuts: shortcuts) == .failed(.showEmoji))
  }
}
