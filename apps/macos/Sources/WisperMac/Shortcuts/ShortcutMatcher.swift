import Foundation
import WisperDomain

/// What `ShortcutMonitor` reports.
///
/// Every `down` is followed by exactly one of `up`, `abandoned` or `cancel`.
public enum ShortcutEvent: Sendable, Equatable {
  /// The shortcut was pressed. For a hold action (push to talk, command mode)
  /// this is the moment to start.
  case down(ShortcutAction)
  /// The shortcut was released: finish what `down` started.
  case up(ShortcutAction)
  /// The press was not what it looked like. No `up` follows.
  ///
  /// With `replacedBy` set, the user went on to a longer shortcut (held fn,
  /// then pressed Space): `down` for that action comes right after, and what
  /// was started can be carried over to it instead of thrown away.
  /// With `replacedBy` nil, the keys were used for their normal job
  /// (fn + an arrow key): throw away what `down` started.
  case abandoned(ShortcutAction, replacedBy: ShortcutAction?)
  /// Escape was pressed while a shortcut was held or while
  /// `ShortcutMonitor.cancelsOnEscape` was on. Throw the dictation away.
  /// No `up` follows for anything that was held.
  case cancel
}

/// One thing that happened on the keyboard, reduced to what matching needs.
enum KeyInput: Sendable, Equatable {
  /// The set of held modifier keys changed.
  case modifiers(Set<KeyCombo.Modifier>)
  /// A key went down. `modifiers` are the ones on the event; fn among them is
  /// ignored, because arrow and function keys carry the fn flag on their own.
  case keyDown(UInt16, modifiers: Set<KeyCombo.Modifier>, isRepeat: Bool)
  case keyUp(UInt16)
}

/// Turns a stream of key presses into shortcut events. Pure: no clock, no
/// system calls, so every rule can be tested with a made-up sequence.
///
/// The rules:
/// - A modifiers-only shortcut fires the moment exactly its modifiers are
///   held, and only when a modifier was just pressed (never when one was
///   released). It ends (`up`) when any of its modifiers lifts. Pressing an
///   extra modifier that completes no shortcut changes nothing.
/// - There is no waiting to see what comes next: push to talk starts at once.
///   When the user goes on to a longer shortcut, the first one is reported as
///   `abandoned(replacedBy:)` and the longer one as `down`.
/// - Another key pressed within `slipWindow` of a modifiers-only `down` means
///   the modifier was being used for its normal job (fn + arrow), so the
///   action is `abandoned`. After the window the key is ignored, so a long
///   dictation is not lost to a bumped key.
/// - A shortcut with a key fires on key down, ignores key repeat, and ends on
///   key up or when one of its modifiers lifts, whichever comes first.
/// - Escape cancels while anything is held, or while `cancelsOnEscape` is on.
/// - The Globe key's own key press (see `globeKeyCode`) is never "another key": it changes
///   nothing that is held. It is kept from the system while `holdsBackGlobeKey` is on.
struct ShortcutMatcher: Sendable {
  struct Output: Equatable, Sendable {
    var events: [ShortcutEvent] = []
    /// The key press belongs to a shortcut and must not reach the app in front.
    var swallow = false
  }

  /// How long after a modifiers-only `down` another key still counts as
  /// "the modifier was meant for that key", in seconds.
  static let slipWindow: TimeInterval = 1.0

  /// The key press macOS makes up when fn (Globe) is pressed and let go with nothing else.
  /// It comes besides the fn key's own modifier change, and it is what sets off the system's
  /// Globe-key action (the emoji picker, the next keyboard language).
  static let globeKeyCode: UInt16 = 179

  var shortcuts: [ShortcutAction: KeyCombo] = [:]
  /// Escape cancels even when no shortcut is held (hands-free dictation is running).
  var cancelsOnEscape = false
  /// Keep the Globe key's own key press from the system, so its action does not run.
  var holdsBackGlobeKey = false

  /// The modifier keys the matcher believes are held.
  private(set) var modifiers: Set<KeyCombo.Modifier> = []
  private var heldModifierAction: HeldModifiers?
  private var heldKeyActions: [UInt16: HeldKey] = [:]
  private var swallowedKeys: Set<UInt16> = []

  private struct HeldModifiers: Sendable {
    var action: ShortcutAction
    var modifiers: Set<KeyCombo.Modifier>
    var since: TimeInterval
  }

  private struct HeldKey: Sendable {
    var action: ShortcutAction
    var modifiers: Set<KeyCombo.Modifier>
  }

  /// A shortcut is down and has not been released yet.
  var isHolding: Bool { heldModifierAction != nil || !heldKeyActions.isEmpty }

  /// Keys the matcher is waiting to see released.
  var trackedKeys: Set<UInt16> { swallowedKeys.union(heldKeyActions.keys) }

  /// `time` is any steadily rising clock, in seconds.
  mutating func handle(_ input: KeyInput, at time: TimeInterval) -> Output {
    switch input {
    case .modifiers(let new):
      return Output(events: changeModifiers(to: new, at: time, mayFire: true))
    case .keyDown(Self.globeKeyCode, _, _), .keyUp(Self.globeKeyCode):
      // Part of pressing fn itself, not a second key: a held push to talk carries on.
      return Output(swallow: holdsBackGlobeKey)
    case .keyDown(let code, let eventModifiers, let isRepeat):
      return keyDown(code, eventModifiers: eventModifiers, isRepeat: isRepeat, at: time)
    case .keyUp(let code):
      return keyUp(code)
    }
  }

  /// Brings the matcher in line with what is really held, after events may
  /// have been missed. `modifiers` are the ones the system says are down and
  /// `releasedKeys` the tracked keys it says are up. Ends what is no longer
  /// held; never starts anything.
  mutating func resync(
    modifiers systemModifiers: Set<KeyCombo.Modifier>,
    releasedKeys: Set<UInt16>,
    at time: TimeInterval
  ) -> [ShortcutEvent] {
    var events = changeModifiers(to: modifiers.intersection(systemModifiers), at: time, mayFire: false)
    for key in releasedKeys.sorted() { events += keyUp(key).events }
    return events
  }

  /// Forgets everything that is held and reports each as `abandoned`.
  /// `modifiers` are the ones held right now, so that they do not look like
  /// a fresh press afterwards.
  mutating func reset(modifiers held: Set<KeyCombo.Modifier> = []) -> [ShortcutEvent] {
    var events: [ShortcutEvent] = []
    if let action = heldModifierAction?.action { events.append(.abandoned(action, replacedBy: nil)) }
    for key in heldKeyActions.keys.sorted() {
      if let action = heldKeyActions[key]?.action { events.append(.abandoned(action, replacedBy: nil)) }
    }
    heldModifierAction = nil
    heldKeyActions.removeAll()
    swallowedKeys.removeAll()
    modifiers = held
    return events
  }

  // MARK: - Modifiers

  private mutating func changeModifiers(
    to new: Set<KeyCombo.Modifier>,
    at time: TimeInterval,
    mayFire: Bool
  ) -> [ShortcutEvent] {
    let old = modifiers
    guard new != old else { return [] }
    modifiers = new
    var events: [ShortcutEvent] = []

    // A shortcut with a key ends as soon as one of its modifiers lifts.
    for key in heldKeyActions.keys.sorted() {
      guard let held = heldKeyActions[key], !held.modifiers.isSubset(of: new) else { continue }
      heldKeyActions[key] = nil
      events.append(.up(held.action))
    }

    if let held = heldModifierAction, !held.modifiers.isSubset(of: new) {
      heldModifierAction = nil
      events.append(.up(held.action))
    }

    // Only a press can start something, and not while a key shortcut is held.
    let pressed = !new.subtracting(old).isEmpty
    guard mayFire, pressed, heldKeyActions.isEmpty, let next = modifiersOnlyAction(for: new) else {
      return events
    }
    if let held = heldModifierAction {
      guard held.action != next else { return events }
      events.append(.abandoned(held.action, replacedBy: next))
    }
    heldModifierAction = HeldModifiers(action: next, modifiers: new, since: time)
    events.append(.down(next))
    return events
  }

  // MARK: - Keys

  private mutating func keyDown(
    _ code: UInt16,
    eventModifiers: Set<KeyCombo.Modifier>,
    isRepeat: Bool,
    at time: TimeInterval
  ) -> Output {
    var output = Output()
    if isRepeat || heldKeyActions[code] != nil {
      output.swallow = swallowedKeys.contains(code)
      return output
    }
    swallowedKeys.remove(code)

    // The event knows the modifiers better than we do if a change was missed.
    // fn is the exception: it is only trusted from modifier changes.
    let fresh = eventModifiers.subtracting([.function]).union(modifiers.intersection([.function]))
    output.events += changeModifiers(to: fresh, at: time, mayFire: false)

    if let action = keyAction(for: code) {
      if let held = heldModifierAction {
        heldModifierAction = nil
        output.events.append(.abandoned(held.action, replacedBy: action))
      }
      heldKeyActions[code] = HeldKey(action: action, modifiers: modifiers)
      swallowedKeys.insert(code)
      output.events.append(.down(action))
      output.swallow = true
      return output
    }

    if code == KeyCombo.KeyCode.escape, isHolding || (cancelsOnEscape && modifiers.isEmpty) {
      heldModifierAction = nil
      heldKeyActions.removeAll()
      swallowedKeys.insert(code)
      output.events.append(.cancel)
      output.swallow = true
      return output
    }

    // A key that belongs to no shortcut.
    if let held = heldModifierAction, time - held.since <= Self.slipWindow {
      heldModifierAction = nil
      output.events.append(.abandoned(held.action, replacedBy: nil))
    }
    return output
  }

  private mutating func keyUp(_ code: UInt16) -> Output {
    var output = Output()
    output.swallow = swallowedKeys.remove(code) != nil
    if let held = heldKeyActions.removeValue(forKey: code) { output.events.append(.up(held.action)) }
    return output
  }

  // MARK: - Lookup

  private func modifiersOnlyAction(for held: Set<KeyCombo.Modifier>) -> ShortcutAction? {
    ShortcutAction.allCases.first { action in
      guard let combo = shortcuts[action] else { return false }
      return combo.isModifiersOnly && combo.modifiers == held
    }
  }

  private func keyAction(for code: UInt16) -> ShortcutAction? {
    ShortcutAction.allCases.first { action in
      guard let combo = shortcuts[action] else { return false }
      return combo.keyCode == code && combo.modifiers == modifiers
    }
  }
}
