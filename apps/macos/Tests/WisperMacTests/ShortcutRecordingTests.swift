import Testing
import WisperDomain

@testable import WisperMac

private func down(_ code: UInt16, _ modifiers: Set<KeyCombo.Modifier> = [], isRepeat: Bool = false)
  -> KeyInput
{
  .keyDown(code, modifiers: modifiers, isRepeat: isRepeat)
}

@Suite struct ShortcutCaptureTests {
  @Test func modifiersAloneAreTakenWhenReleased() {
    var capture = ShortcutCapture()
    #expect(capture.handle(.modifiers([.function])) == .waiting(held: KeyCombo(modifiers: [.function])))
    #expect(capture.handle(.modifiers([])) == .finished(KeyCombo(modifiers: [.function])))
  }

  @Test func allModifiersHeldTogetherAreKept() {
    var capture = ShortcutCapture()
    _ = capture.handle(.modifiers([.function]))
    let both = KeyCombo(modifiers: [.function, .control])
    #expect(capture.handle(.modifiers([.function, .control])) == .waiting(held: both))
    // Whichever one lifts first, the shortcut is both.
    #expect(capture.handle(.modifiers([.function])) == .finished(both))
  }

  @Test func aKeyFinishesAtOnce() {
    var capture = ShortcutCapture()
    _ = capture.handle(.modifiers([.control]))
    _ = capture.handle(.modifiers([.control, .command]))
    let expected = KeyCombo(keyCode: KeyCombo.KeyCode.v, modifiers: [.control, .command])
    #expect(capture.handle(down(KeyCombo.KeyCode.v, [.control, .command])) == .finished(expected))
  }

  @Test func escapeAloneCancels() {
    var capture = ShortcutCapture()
    #expect(capture.handle(down(KeyCombo.KeyCode.escape)) == .cancelled)
  }

  @Test func escapeWithModifiersIsRecordedSoTheRulesCanExplain() {
    var capture = ShortcutCapture()
    _ = capture.handle(.modifiers([.command]))
    let expected = KeyCombo(keyCode: KeyCombo.KeyCode.escape, modifiers: [.command])
    #expect(capture.handle(down(KeyCombo.KeyCode.escape, [.command])) == .finished(expected))
    #expect(expected.problem(for: .pushToTalk, in: [:]) == .usesEscape)
  }

  @Test func theFnFlagOfAnArrowKeyIsLeftOut() {
    var capture = ShortcutCapture()
    #expect(capture.handle(down(123, [.function])) == .finished(KeyCombo(keyCode: 123)))
    capture = ShortcutCapture()
    _ = capture.handle(.modifiers([.function]))
    #expect(
      capture.handle(down(123, [.function])) == .finished(KeyCombo(keyCode: 123, modifiers: [.function]))
    )
  }

  @Test func repeatsAndReleasesOfOtherKeysAreIgnored() {
    var capture = ShortcutCapture()
    #expect(capture.handle(.keyUp(36)) == .waiting(held: KeyCombo()))
    #expect(capture.handle(down(36, isRepeat: true)) == .waiting(held: KeyCombo()))
  }
}

@Suite struct ShortcutRulesTests {
  private let defaults = Settings.defaultShortcuts

  @Test func everyDefaultShortcutIsUsable() {
    for (action, combo) in defaults {
      #expect(combo.problem(for: action, in: defaults) == nil, "\(action)")
    }
  }

  @Test(arguments: [
    (KeyCombo(), ShortcutProblem.empty),
    (KeyCombo(keyCode: 0), .needsModifier),
    (KeyCombo(keyCode: KeyCombo.KeyCode.space), .needsModifier),
    (KeyCombo(keyCode: 123), .needsModifier),
    (KeyCombo(keyCode: 0, modifiers: [.shift]), .usedForTyping),
    (KeyCombo(modifiers: [.shift]), .usedForTyping),
    (KeyCombo(modifiers: [.command]), .commandAlone),
    (KeyCombo(keyCode: KeyCombo.KeyCode.escape), .usesEscape),
    (KeyCombo(keyCode: KeyCombo.KeyCode.escape, modifiers: [.option, .command]), .usesEscape),
    (KeyCombo(keyCode: KeyCombo.KeyCode.space, modifiers: [.command]), .reserved(by: "Spotlight")),
    (KeyCombo(keyCode: 48, modifiers: [.command]), .reserved(by: "switching apps")),
    (KeyCombo(keyCode: KeyCombo.KeyCode.v, modifiers: [.command]), .reserved(by: "pasting")),
    (KeyCombo(keyCode: 14, modifiers: [.function]), .reserved(by: "the emoji picker")),
  ])
  func unusableCombinationsAreExplained(combo: KeyCombo, problem: ShortcutProblem) {
    #expect(combo.problem(for: .toggleMeeting, in: defaults) == problem)
    #expect(!problem.message.isEmpty)
  }

  @Test(arguments: [
    KeyCombo(keyCode: 96),  // F5 on its own
    KeyCombo(keyCode: 105, modifiers: [.shift]),  // ⇧F13
    KeyCombo(modifiers: [.option]),
    KeyCombo(modifiers: [.control]),
    KeyCombo(modifiers: [.shift, .command]),
    KeyCombo(keyCode: 2, modifiers: [.control, .option]),
    KeyCombo(keyCode: KeyCombo.KeyCode.space, modifiers: [.option]),
  ])
  func usableCombinationsPass(combo: KeyCombo) {
    #expect(combo.problem(for: .toggleMeeting, in: defaults) == nil)
  }

  @Test func theSameCombinationTwiceIsAConflict() {
    let fn = KeyCombo(modifiers: [.function])
    #expect(fn.problem(for: .commandMode, in: defaults) == .conflict(with: .pushToTalk))
    #expect(ShortcutProblem.conflict(with: .pushToTalk).message.contains("Push to talk"))
    // Keeping your own shortcut is not a conflict.
    #expect(fn.problem(for: .pushToTalk, in: defaults) == nil)
    // Sharing a beginning is fine: the longer one wins when pressed.
    #expect(KeyCombo(modifiers: [.function, .option]).problem(for: .commandMode, in: defaults) == nil)
  }
}

@MainActor
@Suite struct KeyCapsTests {
  @Test func defaultShortcutsReadAsKeyCaps() {
    let shortcuts = Settings.defaultShortcuts
    #expect(shortcuts[.pushToTalk]?.keyCaps == ["fn"])
    #expect(shortcuts[.handsFree]?.keyCaps == ["fn", "Space"])
    #expect(shortcuts[.commandMode]?.keyCaps == ["fn", "⌃"])
    let letterV = KeyNames.name(for: KeyCombo.KeyCode.v)
    #expect(shortcuts[.pasteLast]?.keyCaps == ["⌃", "⌘", letterV])
    #expect(shortcuts[.toggleMeeting]?.keyCaps == ["⌃", "⌥", KeyNames.name(for: KeyCombo.KeyCode.m)])
  }

  @Test func modifiersComeInTheUsualOrder() {
    let all = KeyCombo(keyCode: 36, modifiers: Set(KeyCombo.Modifier.allCases))
    #expect(all.keyCaps == ["fn", "⌃", "⌥", "⇧", "⌘", "Return"])
    #expect(all.spokenName == "Function Control Option Shift Command Return")
  }

  @Test(arguments: [
    (UInt16(49), "Space"), (36, "Return"), (48, "Tab"), (51, "Delete"), (53, "Esc"), (123, "←"), (126, "↑"),
    (122, "F1"), (111, "F12"), (90, "F20"), (117, "⌦"), (82, "Keypad 0"),
  ])
  func specialKeysHaveNames(keyCode: UInt16, name: String) {
    #expect(KeyNames.name(for: keyCode) == name)
  }

  @Test func lettersComeFromTheKeyboardLayout() throws {
    let name = KeyNames.name(for: KeyCombo.KeyCode.v)
    #expect(name.count == 1)
    #expect(name == name.uppercased())
    // Whatever the layout, some key pastes, and it is found without guessing.
    let pasteKey = try #require(KeyboardLayout.keyCode(forCommand: "v"))
    #expect(pasteKey <= 50)
    #expect(KeyboardLayout.keyCode(forCommand: "c") != pasteKey)
  }

  @Test func symbolsAreSpokenAsWords() {
    #expect(KeyCombo(keyCode: 123, modifiers: [.control]).spokenName == "Control Left Arrow")
    #expect(KeyCombo(modifiers: [.function]).spokenName == "Function")
  }

  @Test func aKeyNobodyKnowsStillGetsALabel() {
    #expect(KeyNames.name(for: 250) == "Key 250")
  }
}
