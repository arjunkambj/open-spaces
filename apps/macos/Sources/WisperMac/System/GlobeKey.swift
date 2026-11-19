import AppKit

/// What macOS itself does when the fn (Globe) key is pressed.
///
/// fn is the default push-to-talk key. If macOS is set to open the emoji
/// picker or switch keyboard language on fn, that happens on every dictation.
/// Open Wisper cannot switch it off, only tell the user where to do so.
public enum GlobeKey {
  public enum SystemUse: Sendable, Equatable {
    case nothing
    case changeInputSource
    case showEmoji
    case startDictation
    /// Never set by the user: macOS decides (usually the emoji picker).
    case systemDefault
  }

  /// The user's choice under System Settings > Keyboard > "Press 🌐 key to".
  public static var systemUse: SystemUse {
    systemUse(setting: UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType"))
  }

  /// True when pressing fn alone also sets something off in macOS.
  public static var interferes: Bool { systemUse != .nothing }

  /// Opens System Settings > Keyboard, where "Press 🌐 key to" lives.
  @MainActor public static func openSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  static func systemUse(setting: Any?) -> SystemUse {
    switch (setting as? NSNumber)?.intValue {
    case 0: .nothing
    case 1: .changeInputSource
    case 2: .showEmoji
    case 3: .startDictation
    default: .systemDefault
    }
  }
}
