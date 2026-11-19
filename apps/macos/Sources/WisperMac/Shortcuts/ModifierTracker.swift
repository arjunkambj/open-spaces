import WisperDomain

/// Works out which modifier keys are held from the flags on keyboard events.
///
/// Every modifier but fn can be read straight off an event. fn needs care:
/// - Arrow keys, function keys, Home, End and forward Delete carry the fn flag
///   whether or not fn is held, so the flag on a key press is never believed.
/// - The fn (Globe) key's own event is the one sure sign of a press or a
///   release, so only that event can turn fn off.
/// - The flag on another modifier's event can turn fn on (it is only there
///   while fn is held), but its absence proves nothing.
struct ModifierTracker: Sendable {
  /// Key codes the fn (Globe) key reports itself with.
  static let functionKeyCodes: Set<UInt16> = [63, 179]

  private(set) var isFunctionDown: Bool

  init(isFunctionDown: Bool = false) {
    self.isFunctionDown = isFunctionDown
  }

  /// A modifier key changed. `flags` are the modifiers on the event and
  /// `keyCode` is the key that changed. Returns the modifiers now held.
  mutating func modifierChanged(flags: Set<KeyCombo.Modifier>, keyCode: UInt16) -> Set<KeyCombo.Modifier> {
    if Self.functionKeyCodes.contains(keyCode) {
      isFunctionDown = flags.contains(.function)
    } else if flags.contains(.function) {
      isFunctionDown = true
    }
    var held = flags.subtracting([.function])
    if isFunctionDown { held.insert(.function) }
    return held
  }

  /// The system says fn is up. Used to recover after a missed release.
  mutating func functionReleased() { isFunctionDown = false }
}
