import Foundation
import Testing
import WisperDomain

@testable import WisperMac

/// One line of a made-up key sequence: what happens, when, and what must come out.
private struct Step {
  var input: KeyInput
  var time: TimeInterval
  var events: [ShortcutEvent]
  var swallow: Bool
  var line: Int

  init(
    _ input: KeyInput,
    at time: TimeInterval = 0,
    _ events: [ShortcutEvent] = [],
    swallow: Bool = false,
    line: Int = #line
  ) {
    self.input = input
    self.time = time
    self.events = events
    self.swallow = swallow
    self.line = line
  }
}

private let fn: Set<KeyCombo.Modifier> = [.function]
private let space = KeyCombo.KeyCode.space
private let keyV = KeyCombo.KeyCode.v
private let keyM = KeyCombo.KeyCode.m
private let escape = KeyCombo.KeyCode.escape
private let leftArrow: UInt16 = 123

private func down(_ code: UInt16, _ modifiers: Set<KeyCombo.Modifier> = [], isRepeat: Bool = false)
  -> KeyInput
{
  .keyDown(code, modifiers: modifiers, isRepeat: isRepeat)
}

private func check(
  _ steps: [Step],
  shortcuts: [ShortcutAction: KeyCombo] = Settings.defaultShortcuts,
  cancelsOnEscape: Bool = false
) {
  var matcher = ShortcutMatcher(shortcuts: shortcuts)
  matcher.cancelsOnEscape = cancelsOnEscape
  for step in steps {
    let output = matcher.handle(step.input, at: step.time)
    #expect(output.events == step.events, "events at line \(step.line)")
    #expect(output.swallow == step.swallow, "swallow at line \(step.line)")
  }
}

@Suite struct ShortcutMatcherTests {
  @Test func holdingFnIsPushToTalk() {
    check([
      Step(.modifiers(fn), [.down(.pushToTalk)]),
      Step(.modifiers([]), at: 5, [.up(.pushToTalk)]),
    ])
  }

  @Test func fnThenControlBecomesCommandMode() {
    check([
      Step(.modifiers(fn), [.down(.pushToTalk)]),
      Step(
        .modifiers([.function, .control]),
        at: 0.1,
        [.abandoned(.pushToTalk, replacedBy: .commandMode), .down(.commandMode)]
      ),
      Step(.modifiers([.control]), at: 3, [.up(.commandMode)]),
      Step(.modifiers([]), at: 3.1),
    ])
  }

  @Test func controlThenFnIsCommandModeWithoutPushToTalk() {
    check([
      Step(.modifiers([.control])),
      Step(.modifiers([.function, .control]), [.down(.commandMode)]),
      Step(.modifiers([]), at: 2, [.up(.commandMode)]),
    ])
  }

  @Test func releasingInAnotherOrderDoesNotStartPushToTalk() {
    check([
      Step(.modifiers(fn), [.down(.pushToTalk)]),
      Step(
        .modifiers([.function, .control]),
        [.abandoned(.pushToTalk, replacedBy: .commandMode), .down(.commandMode)]
      ),
      // ⌃ lifts first: fn is still down, but nothing was pressed, so nothing starts.
      Step(.modifiers(fn), at: 2, [.up(.commandMode)]),
      Step(.modifiers([]), at: 2.2),
    ])
  }

  @Test func pressingControlAgainWhileFnIsStillHeldStartsCommandModeAgain() {
    check([
      Step(.modifiers([.function, .control]), [.down(.commandMode)]),
      Step(.modifiers(fn), at: 1, [.up(.commandMode)]),
      Step(.modifiers([.function, .control]), at: 2, [.down(.commandMode)]),
      Step(.modifiers([]), at: 3, [.up(.commandMode)]),
    ])
  }

  @Test func fnThenSpaceIsHandsFreeAndPushToTalkIsAbandoned() {
    check([
      Step(.modifiers(fn), [.down(.pushToTalk)]),
      Step(
        down(space),
        at: 0.2,
        [.abandoned(.pushToTalk, replacedBy: .handsFree), .down(.handsFree)],
        swallow: true
      ),
      Step(down(space, isRepeat: true), at: 0.7, swallow: true),
      Step(.keyUp(space), at: 0.8, [.up(.handsFree)], swallow: true),
      Step(.modifiers([]), at: 0.9),
    ])
  }

  @Test func aLongerShortcutWinsHoweverLateItComes() {
    check([
      Step(.modifiers(fn), [.down(.pushToTalk)]),
      Step(
        down(space),
        at: 30,
        [.abandoned(.pushToTalk, replacedBy: .handsFree), .down(.handsFree)],
        swallow: true
      ),
      Step(.keyUp(space), at: 30.1, [.up(.handsFree)], swallow: true),
    ])
  }

  @Test func spaceTwiceWhileFnStaysDownTogglesTwice() {
    check([
      Step(.modifiers(fn), [.down(.pushToTalk)]),
      Step(
        down(space),
        [.abandoned(.pushToTalk, replacedBy: .handsFree), .down(.handsFree)],
        swallow: true
      ),
      Step(.keyUp(space), [.up(.handsFree)], swallow: true),
      Step(down(space), at: 4, [.down(.handsFree)], swallow: true),
      Step(.keyUp(space), at: 4.1, [.up(.handsFree)], swallow: true),
      Step(.modifiers([]), at: 5),
    ])
  }

  @Test func anotherKeySoonAfterFnMeansFnWasNotForDictation() {
    check([
      Step(.modifiers(fn), [.down(.pushToTalk)]),
      // fn + arrow: the arrow reaches the app, the dictation is thrown away.
      Step(down(leftArrow, fn), at: 0.3, [.abandoned(.pushToTalk, replacedBy: nil)]),
      Step(.keyUp(leftArrow), at: 0.4),
      Step(down(leftArrow, fn), at: 0.6),
      Step(.keyUp(leftArrow), at: 0.7),
      Step(.modifiers([]), at: 1),
    ])
  }

  @Test func aKeyBumpedDuringALongDictationIsIgnored() {
    check([
      Step(.modifiers(fn), [.down(.pushToTalk)]),
      Step(down(leftArrow, fn), at: ShortcutMatcher.slipWindow + 0.5),
      Step(.keyUp(leftArrow), at: 2),
      Step(.modifiers([]), at: 20, [.up(.pushToTalk)]),
    ])
  }

  @Test func anExtraModifierThatCompletesNothingChangesNothing() {
    check([
      Step(.modifiers(fn), [.down(.pushToTalk)]),
      Step(.modifiers([.function, .shift]), at: 1),
      Step(.modifiers(fn), at: 2),
      Step(.modifiers([]), at: 3, [.up(.pushToTalk)]),
    ])
  }

  @Test func keyRepeatDoesNotFireAgain() {
    check([
      Step(.modifiers([.control])),
      Step(.modifiers([.control, .command])),
      Step(down(keyV, [.control, .command]), [.down(.pasteLast)], swallow: true),
      Step(down(keyV, [.control, .command], isRepeat: true), swallow: true),
      Step(down(keyV, [.control, .command], isRepeat: true), swallow: true),
      // A repeat that arrives without the repeat flag is still a repeat.
      Step(down(keyV, [.control, .command]), swallow: true),
      Step(.keyUp(keyV), [.up(.pasteLast)], swallow: true),
      Step(.modifiers([])),
    ])
  }

  @Test func upComesWhenAModifierLiftsBeforeTheKey() {
    check([
      Step(.modifiers([.control, .option])),
      Step(down(keyM, [.control, .option]), [.down(.toggleMeeting)], swallow: true),
      Step(.modifiers([.option]), [.up(.toggleMeeting)]),
      // The key's own release is still kept from the app, and reports nothing more.
      Step(down(keyM, [.option], isRepeat: true), swallow: true),
      Step(.keyUp(keyM), swallow: true),
      Step(.modifiers([])),
    ])
  }

  @Test func modifiersMustMatchExactly() {
    check([
      Step(.modifiers([.command])),
      Step(down(keyV, [.command])),
      Step(.keyUp(keyV)),
      Step(.modifiers([.control, .option, .shift])),
      Step(down(keyM, [.control, .option, .shift])),
      Step(.keyUp(keyM)),
      Step(.modifiers([])),
      Step(down(space)),
      Step(.keyUp(space)),
    ])
  }

  @Test func aMissedModifierChangeIsReadFromTheKeyEvent() {
    check([
      Step(down(keyM, [.control, .option]), [.down(.toggleMeeting)], swallow: true),
      Step(.keyUp(keyM), [.up(.toggleMeeting)], swallow: true),
      // And a missed release: the next plain key shows the modifiers are gone.
      Step(.modifiers(fn), at: 10, [.down(.pushToTalk)]),
    ])
  }

  @Test func theFnFlagOnArrowKeysIsNotTheFnKey() {
    let shortcuts: [ShortcutAction: KeyCombo] = [
      .pushToTalk: KeyCombo(modifiers: fn),
      .toggleMeeting: KeyCombo(keyCode: leftArrow, modifiers: fn),
    ]
    check(
      [
        // An arrow key always carries the fn flag. On its own it is just an arrow.
        Step(down(leftArrow, fn)),
        Step(.keyUp(leftArrow)),
        // With the fn key really down it is the shortcut.
        Step(.modifiers(fn), at: 5, [.down(.pushToTalk)]),
        Step(
          down(leftArrow, fn),
          at: 5.1,
          [.abandoned(.pushToTalk, replacedBy: .toggleMeeting), .down(.toggleMeeting)],
          swallow: true
        ),
        Step(.keyUp(leftArrow), at: 5.2, [.up(.toggleMeeting)], swallow: true),
      ],
      shortcuts: shortcuts
    )
  }

  @Test func aModifiersOnlyShortcutDoesNotStartWhileAKeyShortcutIsHeld() {
    check([
      Step(.modifiers(fn), [.down(.pushToTalk)]),
      Step(
        down(space),
        [.abandoned(.pushToTalk, replacedBy: .handsFree), .down(.handsFree)],
        swallow: true
      ),
      Step(.modifiers([.function, .control])),
      Step(.keyUp(space), [.up(.handsFree)], swallow: true),
      Step(.modifiers([])),
    ])
  }

  @Test func aShortcutWithAKeyCanBeHeld() {
    let keyD: UInt16 = 2
    check(
      [
        Step(.modifiers([.control, .option])),
        Step(down(keyD, [.control, .option]), [.down(.pushToTalk)], swallow: true),
        Step(down(keyD, [.control, .option], isRepeat: true), at: 3, swallow: true),
        // Other keys do not disturb it, early or late.
        Step(down(leftArrow, [.control, .option]), at: 0.2),
        Step(.keyUp(leftArrow), at: 0.3),
        Step(.keyUp(keyD), at: 6, [.up(.pushToTalk)], swallow: true),
      ],
      shortcuts: [.pushToTalk: KeyCombo(keyCode: keyD, modifiers: [.control, .option])]
    )
  }

  // MARK: Escape

  @Test func escapeIsAnOrdinaryKeyWhenNothingIsActive() {
    check([
      Step(down(escape)),
      Step(.keyUp(escape)),
    ])
  }

  @Test func escapeCancelsWhatIsHeld() {
    check([
      Step(.modifiers(fn), [.down(.pushToTalk)]),
      Step(down(escape), at: 4, [.cancel], swallow: true),
      Step(down(escape, isRepeat: true), at: 4.5, swallow: true),
      Step(.keyUp(escape), at: 4.6, swallow: true),
      // No `up` after a cancel.
      Step(.modifiers([]), at: 5),
      // And Escape is ordinary again.
      Step(down(escape), at: 6),
    ])
  }

  @Test func escapeCancelsAHandsFreeDictationWhenAsked() {
    check(
      [
        Step(down(escape), [.cancel], swallow: true),
        Step(.keyUp(escape), swallow: true),
        // ⌥⌘Esc (Force Quit) is somebody else's shortcut.
        Step(.modifiers([.option, .command])),
        Step(down(escape, [.option, .command])),
      ],
      cancelsOnEscape: true
    )
  }

  // MARK: Recovering

  @Test func resyncEndsWhatIsNoLongerHeldAndStartsNothing() {
    var matcher = ShortcutMatcher(shortcuts: Settings.defaultShortcuts)
    #expect(matcher.handle(.modifiers(fn), at: 0).events == [.down(.pushToTalk)])
    #expect(matcher.resync(modifiers: fn, at: 1).isEmpty)
    #expect(matcher.resync(modifiers: [.function, .control], at: 1).isEmpty)
    #expect(matcher.resync(modifiers: [], at: 2) == [.up(.pushToTalk)])
    #expect(!matcher.isHolding)
    #expect(matcher.resync(modifiers: fn, at: 3).isEmpty)
    #expect(matcher.modifiers.isEmpty)
  }

  @Test func resyncReleasesAKeyWhoseReleaseWasMissed() {
    var matcher = ShortcutMatcher(shortcuts: Settings.defaultShortcuts)
    _ = matcher.handle(.modifiers([.control, .option]), at: 0)
    #expect(matcher.handle(down(keyM, [.control, .option]), at: 0).events == [.down(.toggleMeeting)])
    #expect(matcher.trackedKeys == [keyM])
    #expect(
      matcher.resync(modifiers: [.control, .option], releasedKeys: [keyM], at: 1) == [.up(.toggleMeeting)]
    )
    #expect(matcher.trackedKeys.isEmpty)
  }

  @Test func resetAbandonsEverythingAndHeldModifiersAreNotAFreshPress() {
    var matcher = ShortcutMatcher(shortcuts: Settings.defaultShortcuts)
    _ = matcher.handle(.modifiers(fn), at: 0)
    #expect(matcher.reset(modifiers: fn) == [.abandoned(.pushToTalk, replacedBy: nil)])
    #expect(matcher.handle(.modifiers(fn), at: 1).events.isEmpty)
    #expect(matcher.handle(.modifiers([]), at: 2).events.isEmpty)
    #expect(matcher.handle(.modifiers(fn), at: 3).events == [.down(.pushToTalk)])
    #expect(matcher.reset() == [.abandoned(.pushToTalk, replacedBy: nil)])
    #expect(matcher.reset().isEmpty)
  }

  // MARK: The promise

  /// Whatever is typed, every `down` gets exactly one `up`, `abandoned` or
  /// `cancel`, and a key that was held back has its release held back too.
  @Test(arguments: 0..<40) func everyDownIsClosed(seed: UInt64) {
    var random = SeededGenerator(state: seed &* 0x9E37_79B9_7F4A_7C15 &+ 1)
    var matcher = ShortcutMatcher(shortcuts: Settings.defaultShortcuts)
    matcher.cancelsOnEscape = seed.isMultiple(of: 3)
    var open: Set<ShortcutAction> = []
    var modifiers: Set<KeyCombo.Modifier> = []
    var keysDown: [UInt16: Bool] = [:]
    var time: TimeInterval = 0
    let keys: [UInt16] = [space, keyV, keyM, escape, leftArrow, 0]

    func apply(_ events: [ShortcutEvent]) {
      for event in events {
        switch event {
        case .down(let action):
          #expect(!open.contains(action), "\(action) went down twice (seed \(seed))")
          open.insert(action)
        case .up(let action), .abandoned(let action, _):
          #expect(open.contains(action), "\(action) closed without a down (seed \(seed))")
          open.remove(action)
        case .cancel:
          open.removeAll()
        }
      }
    }

    for _ in 0..<400 {
      time += Double.random(in: 0...0.8, using: &random)
      switch Int.random(in: 0..<3, using: &random) {
      case 0:
        let modifier = KeyCombo.Modifier.allCases.randomElement(using: &random)!
        if modifiers.contains(modifier) { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
        apply(matcher.handle(.modifiers(modifiers), at: time).events)
      case 1:
        let key = keys.randomElement(using: &random)!
        let output = matcher.handle(down(key, modifiers, isRepeat: keysDown[key] != nil), at: time)
        if keysDown[key] == nil { keysDown[key] = output.swallow }
        apply(output.events)
      default:
        guard let key = keysDown.keys.sorted().randomElement(using: &random) else { continue }
        let output = matcher.handle(.keyUp(key), at: time)
        #expect(output.swallow == keysDown[key], "release of \(key) treated unlike its press (seed \(seed))")
        keysDown[key] = nil
        apply(output.events)
      }
    }
    // Let go of everything.
    for key in keysDown.keys.sorted() { apply(matcher.handle(.keyUp(key), at: time).events) }
    apply(matcher.handle(.modifiers([]), at: time).events)
    #expect(open.isEmpty, "left open: \(open) (seed \(seed))")
    #expect(!matcher.isHolding)
  }
}

@Suite struct ModifierTrackerTests {
  private let fnKey: UInt16 = 63
  private let controlKey: UInt16 = 59

  @Test func theFnKeyTurnsFnOnAndOff() {
    var tracker = ModifierTracker()
    #expect(tracker.modifierChanged(flags: [.function], keyCode: fnKey) == [.function])
    #expect(tracker.modifierChanged(flags: [], keyCode: fnKey) == [])
  }

  @Test func fnStaysDownWhenAnotherModifiersEventLeavesItOut() {
    var tracker = ModifierTracker()
    _ = tracker.modifierChanged(flags: [.function], keyCode: fnKey)
    // Whether or not the system repeats the fn flag on ⌃'s event, fn is still held.
    #expect(tracker.modifierChanged(flags: [.control], keyCode: controlKey) == [.function, .control])
    #expect(
      tracker.modifierChanged(flags: [.function, .control], keyCode: controlKey) == [.function, .control]
    )
    #expect(tracker.modifierChanged(flags: [.function], keyCode: controlKey) == [.function])
    #expect(tracker.modifierChanged(flags: [], keyCode: fnKey) == [])
  }

  @Test func fnSeenOnAnotherModifiersEventCounts() {
    // The fn press itself was missed, but ⌃'s event says fn is down.
    var tracker = ModifierTracker()
    #expect(
      tracker.modifierChanged(flags: [.function, .control], keyCode: controlKey) == [.function, .control]
    )
    #expect(tracker.isFunctionDown)
  }

  @Test func aMissedFnReleaseCanBeCorrected() {
    var tracker = ModifierTracker()
    _ = tracker.modifierChanged(flags: [.function], keyCode: fnKey)
    tracker.functionReleased()
    #expect(tracker.modifierChanged(flags: [.command], keyCode: 55) == [.command])
  }

  @Test func theTrackerAndTheMatcherTogetherGiveCommandModeEitherWay() {
    // The same key presses, as reported by a system that repeats the fn flag
    // on other modifiers' events and by one that does not.
    for repeatsFnFlag in [true, false] {
      var tracker = ModifierTracker()
      var matcher = ShortcutMatcher(shortcuts: Settings.defaultShortcuts)
      var events: [ShortcutEvent] = []
      let controlDown: Set<KeyCombo.Modifier> = repeatsFnFlag ? [.function, .control] : [.control]
      let controlUp: Set<KeyCombo.Modifier> = repeatsFnFlag ? [.function] : []
      let steps: [(Set<KeyCombo.Modifier>, UInt16)] = [
        ([.function], fnKey), (controlDown, controlKey), (controlUp, controlKey), ([], fnKey),
      ]
      for (index, step) in steps.enumerated() {
        let held = tracker.modifierChanged(flags: step.0, keyCode: step.1)
        events += matcher.handle(.modifiers(held), at: Double(index)).events
      }
      #expect(
        events == [
          .down(.pushToTalk), .abandoned(.pushToTalk, replacedBy: .commandMode), .down(.commandMode),
          .up(.commandMode),
        ],
        "repeatsFnFlag: \(repeatsFnFlag)"
      )
    }
  }
}

/// A small repeatable random source, so a failing seed can be run again.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
