import SpacesDomain

/// Why a key combination cannot be used as a shortcut.
public enum ShortcutProblem: Sendable, Equatable {
  /// Nothing was pressed.
  case empty
  /// A key on its own (a letter, Space, Return, an arrow...).
  case needsModifier
  /// ⇧ alone, or ⇧ plus a key: that is how capital letters are typed.
  case usedForTyping
  /// ⌘ alone: it starts almost every other shortcut.
  case commandAlone
  /// Escape is the key that cancels a dictation.
  case usesEscape
  /// macOS already uses this. The value says what for, e.g. "Spotlight".
  case reserved(by: String)
  /// Another Spaces action already has this shortcut.
  case conflict(with: ShortcutAction)

  /// A plain-English sentence to show under the shortcut field.
  public var message: String {
    switch self {
    case .empty:
      "Press the keys you want to use."
    case .needsModifier:
      "Add a key such as ⌃, ⌥ or ⌘. A key on its own would stop working for typing."
    case .usedForTyping:
      "⇧ is for typing capital letters. Add ⌃, ⌥ or ⌘ as well."
    case .commandAlone:
      "⌘ on its own starts almost every other shortcut. Add another key."
    case .usesEscape:
      "Escape cancels a dictation, so it cannot be part of a shortcut."
    case .reserved(let what):
      "macOS already uses this for \(what). Pick something else."
    case .conflict(let action):
      "This is already the shortcut for “\(action.label)”."
    }
  }
}

extension KeyCombo {
  /// Checks whether this combination can be the shortcut for `action`, given
  /// the shortcuts in use. Returns nil when it can.
  ///
  /// Two actions may share a beginning (fn and fn+Space): the longer one wins
  /// when it is pressed. Only the very same combination is a conflict.
  public func problem(
    for action: ShortcutAction,
    in shortcuts: [ShortcutAction: KeyCombo]
  ) -> ShortcutProblem? {
    if isEmpty { return .empty }
    if let keyCode {
      if keyCode == KeyCode.escape { return .usesEscape }
      let isFunctionKey = KeyNames.functionKeys[keyCode] != nil
      if modifiers.isEmpty, !isFunctionKey { return .needsModifier }
      if modifiers == [.shift], !isFunctionKey { return .usedForTyping }
    } else {
      if modifiers == [.shift] { return .usedForTyping }
      if modifiers == [.command] { return .commandAlone }
    }
    if let what = SystemShortcuts.use(of: self) { return .reserved(by: what) }
    let other = ShortcutAction.allCases.first { $0 != action && shortcuts[$0] == self }
    if let other { return .conflict(with: other) }
    return nil
  }
}

/// Shortcuts macOS keeps for itself. Add a line to reserve another one.
enum SystemShortcuts {
  static func use(of combo: KeyCombo) -> String? {
    guard let keyCode = combo.keyCode else { return nil }
    return table.first { $0.keyCode == keyCode && $0.modifiers == combo.modifiers }?.use
  }

  private struct Entry {
    var keyCode: UInt16
    var modifiers: Set<KeyCombo.Modifier>
    var use: String
  }

  private static func entry(_ keyCode: UInt16, _ modifiers: Set<KeyCombo.Modifier>, _ use: String) -> Entry {
    Entry(keyCode: keyCode, modifiers: modifiers, use: use)
  }

  // Key codes are positions on the keyboard (the letter names are those of a US layout).
  private static let table: [Entry] = [
    entry(49, [.command], "Spotlight"),
    entry(49, [.option, .command], "searching in Finder"),
    entry(49, [.control], "switching keyboard language"),
    entry(49, [.control, .option], "switching keyboard language"),
    entry(49, [.control, .command], "the emoji picker"),
    entry(48, [.command], "switching apps"),
    entry(48, [.shift, .command], "switching apps"),
    entry(50, [.command], "switching windows"),
    entry(12, [.command], "quitting apps"),
    entry(12, [.shift, .command], "logging out"),
    entry(12, [.control, .command], "locking the screen"),
    entry(13, [.command], "closing windows"),
    entry(4, [.command], "hiding apps"),
    entry(4, [.option, .command], "hiding apps"),
    entry(46, [.command], "minimising windows"),
    entry(8, [.command], "copying"),
    entry(9, [.command], "pasting"),
    entry(7, [.command], "cutting"),
    entry(6, [.command], "undo"),
    entry(6, [.shift, .command], "redo"),
    entry(0, [.command], "selecting everything"),
    entry(1, [.command], "saving"),
    entry(43, [.command], "opening an app's settings"),
    entry(20, [.shift, .command], "screenshots"),
    entry(21, [.shift, .command], "screenshots"),
    entry(23, [.shift, .command], "screenshots"),
    entry(3, [.control, .command], "full screen"),
    entry(2, [.option, .command], "showing and hiding the Dock"),
    entry(126, [.control], "Mission Control"),
    entry(125, [.control], "Mission Control"),
    entry(123, [.control], "switching desktops"),
    entry(124, [.control], "switching desktops"),
    // The Globe (fn) key shortcuts.
    entry(0, [.function], "showing the Dock"),
    entry(8, [.function], "Control Centre"),
    entry(2, [.function], "Apple's dictation"),
    entry(14, [.function], "the emoji picker"),
    entry(3, [.function], "full screen"),
    entry(4, [.function], "showing the desktop"),
    entry(45, [.function], "Notification Centre"),
    entry(12, [.function], "Quick Note"),
  ]
}
