import Carbon.HIToolbox
import SpacesDomain

extension KeyCombo {
  /// The shortcut as key-cap labels, in the order they are shown:
  /// `["fn"]`, `["fn", "Space"]`, `["⌃", "⌘", "V"]`.
  /// Letters follow the user's keyboard layout.
  @MainActor public var keyCaps: [String] {
    orderedModifiers.map(\.symbol) + (keyCode.map { [KeyNames.name(for: $0)] } ?? [])
  }

  /// The shortcut in words, for VoiceOver: "Control Command V".
  @MainActor public var spokenName: String {
    let modifierNames = orderedModifiers.map { modifier in
      switch modifier {
      case .function: "Function"
      case .control: "Control"
      case .option: "Option"
      case .shift: "Shift"
      case .command: "Command"
      }
    }
    let key = keyCode.map { [KeyNames.spokenNames[$0] ?? KeyNames.name(for: $0)] } ?? []
    return (modifierNames + key).joined(separator: " ")
  }
}

/// Names of keys, by key code (a position on the keyboard).
enum KeyNames {
  /// What to print on a key cap for `keyCode`.
  @MainActor static func name(for keyCode: UInt16) -> String {
    if let name = specialKeys[keyCode] ?? functionKeys[keyCode] { return name }
    if let character = KeyboardLayout.character(for: keyCode) { return character.uppercased() }
    return usLayout[keyCode] ?? "Key \(keyCode)"
  }

  static let functionKeys: [UInt16: String] = [
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
    109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
    79: "F18", 80: "F19", 90: "F20",
  ]

  static let specialKeys: [UInt16: String] = [
    36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 76: "Enter", 117: "⌦",
    115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 123: "←", 124: "→", 125: "↓",
    126: "↑", 114: "Help", 71: "Clear", 57: "Caps Lock",
    82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5",
    88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 65: "Keypad .", 67: "Keypad *",
    69: "Keypad +", 75: "Keypad /", 78: "Keypad -", 81: "Keypad =",
  ]

  /// Names VoiceOver should say where the key cap is a symbol.
  static let spokenNames: [UInt16: String] = [
    53: "Escape", 117: "Forward Delete", 123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow",
    126: "Up Arrow",
  ]

  /// Used only when the keyboard layout cannot be read.
  static let usLayout: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
    13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
    24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
    35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
    47: ".", 50: "`",
  ]
}

/// Reads the user's keyboard layout. Main thread only: the system's input
/// source calls are not safe anywhere else.
@MainActor
enum KeyboardLayout {
  /// The character printed on the key at `keyCode`, in the layout used for
  /// shortcuts (for a non-Latin layout that is its Latin partner, which is
  /// what menus show too).
  static func character(for keyCode: UInt16) -> String? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else {
      return nil
    }
    return translate(keyCode, modifiers: 0, in: source)
  }

  /// The key that types `character` while ⌘ is held in the current layout,
  /// i.e. the key an app reads as ⌘+character. Nil when no key does.
  static func keyCode(forCommand character: Character) -> UInt16? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
    let wanted = String(character).lowercased()
    let commandKeyState = UInt32(cmdKey >> 8) & 0xFF
    // Try the usual place first so an ordinary layout costs one lookup.
    for keyCode in [UInt16(kVK_ANSI_V)] + Array(0...50) {
      if translate(keyCode, modifiers: commandKeyState, in: source)?.lowercased() == wanted { return keyCode }
    }
    return nil
  }

  private static func translate(_ keyCode: UInt16, modifiers: UInt32, in source: TISInputSource) -> String? {
    guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
      return nil
    }
    let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
    var deadKeys: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 4)
    let status = data.withUnsafeBytes { bytes -> OSStatus in
      guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
      return UCKeyTranslate(
        layout,
        keyCode,
        UInt16(kUCKeyActionDisplay),
        modifiers,
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit),
        &deadKeys,
        characters.count,
        &length,
        &characters
      )
    }
    guard status == noErr, length > 0 else { return nil }
    let text = String(utf16CodeUnits: characters, count: length)
    guard let first = text.unicodeScalars.first, first.value > 0x20, first.value != 0x7F else { return nil }
    return text
  }
}
