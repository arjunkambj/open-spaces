import AppKit
import Observation
import WisperDomain

/// What macOS itself does when the fn (Globe) key is pressed.
///
/// fn is the default push-to-talk key. If macOS is set to open the emoji
/// picker or switch keyboard language on fn, that can happen on a dictation.
/// `GlobeKeySetting` reads that choice and can switch it off for the user.
public enum GlobeKey {
  /// The choice under System Settings > Keyboard > "Press 🌐 key to".
  public enum SystemUse: Int, Sendable, Equatable, CaseIterable {
    case nothing = 0
    case changeInputSource = 1
    case showEmoji = 2
    case startDictation = 3
    /// Never set by the user, and macOS would not say what it does then (usually the emoji picker).
    case systemDefault = -1

    /// The name of the choice as System Settings shows it.
    public var title: String {
      switch self {
      case .nothing: "Do Nothing"
      case .changeInputSource: "Change Input Source"
      case .showEmoji, .systemDefault: "Show Emoji & Symbols"
      case .startDictation: "Start Dictation"
      }
    }
  }

  /// How a change of the setting went.
  public enum Outcome: Sendable, Equatable {
    /// macOS already behaves the new way.
    case now
    /// macOS did not take the change.
    case failed
  }

  /// The way to the system's setting: how to read it and how to change it.
  ///
  /// The app uses `.live`. The demo and snapshots use `.inert`, so nothing on the Mac is
  /// ever changed by them.
  public struct System: Sendable {
    /// The value macOS has stored (0 to 3), or `nil` when the user never chose.
    var read: @Sendable () -> Int?
    /// Sets the value and says how that went.
    var write: @Sendable (Int) -> Outcome

    /// Reads "Do Nothing" and changes nothing.
    public static let inert = System(read: { SystemUse.nothing.rawValue }, write: { _ in .failed })

    /// The real setting of this Mac.
    public static let live = System(read: { LiveSetting.read() }, write: { LiveSetting.write($0) })
  }

  /// Opens System Settings > Keyboard, where "Press 🌐 key to" lives.
  @MainActor public static func openSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  static func systemUse(setting: Int?) -> SystemUse {
    setting.flatMap(SystemUse.init(rawValue:)) ?? .systemDefault
  }

  /// True when a combination uses the fn key, alone or with other keys.
  public static func isUsed(by shortcuts: [ShortcutAction: KeyCombo]) -> Bool {
    shortcuts.values.contains { !$0.isEmpty && $0.modifiers.contains(.function) }
  }
}

/// The Mac's fn (Globe) key setting, and the one-click way to stop macOS reacting to the key.
///
/// ```swift
/// let globe = GlobeKeySetting(system: .live, memory: .standard)
/// if globe.needsFix(for: settings.shortcuts) { /* offer the fix */ }
/// let outcome = globe.fix()        // sets "Press 🌐 key to" to "Do Nothing"
/// ```
///
/// What a caller can rely on:
/// - `systemUse` is what was last read. Call `refresh()` to read again; a view that shows
///   the hint does that about once a second, so the hint goes away by itself.
/// - `fix()` writes exactly one thing: "Do Nothing". It remembers what the setting was
///   before (`previousUse`), so the user can be told how to put it back.
/// - Once the user sets the key back to something else in System Settings, what was
///   remembered is forgotten.
/// - `shouldAsk(for:)` is true at most until `markAsked()`: the app asks once, ever.
@MainActor
@Observable
public final class GlobeKeySetting {
  /// What macOS does on fn, as last read.
  public private(set) var systemUse: GlobeKey.SystemUse
  /// How the fix went, when it was made since the app started.
  public private(set) var outcome: GlobeKey.Outcome?
  /// What the setting was before `fix()` changed it; `nil` when the app never changed it.
  public private(set) var previousUse: GlobeKey.SystemUse?
  /// The app has already asked, once, whether to make the fix.
  public private(set) var wasAsked: Bool

  @ObservationIgnored private let system: GlobeKey.System
  @ObservationIgnored private let memory: UserDefaults?

  private enum Key {
    static let previous = "globeKey.previousUse"
    static let asked = "globeKey.asked"
  }

  /// - system: how to reach the Mac's setting: `.live`, or `.inert` for the demo.
  /// - memory: where the choice before the fix and "already asked" are kept, or `nil` to keep nothing.
  public init(system: GlobeKey.System, memory: UserDefaults?) {
    self.system = system
    self.memory = memory
    systemUse = GlobeKey.systemUse(setting: system.read())
    previousUse = (memory?.object(forKey: Key.previous) as? Int).flatMap(GlobeKey.SystemUse.init(rawValue:))
    wasAsked = memory?.bool(forKey: Key.asked) ?? false
    forgetIfChangedBack()
  }

  /// True when pressing fn alone also sets something off in macOS.
  public var interferes: Bool { systemUse != .nothing }

  /// The fix is worth offering: fn is part of one of the shortcuts and macOS reacts to the key too.
  public func needsFix(for shortcuts: [ShortcutAction: KeyCombo]) -> Bool {
    interferes && GlobeKey.isUsed(by: shortcuts)
  }

  /// The one-time question should be put now.
  public func shouldAsk(for shortcuts: [ShortcutAction: KeyCombo]) -> Bool {
    !wasAsked && needsFix(for: shortcuts)
  }

  /// The question was put. It is never put again.
  public func markAsked() {
    wasAsked = true
    memory?.set(true, forKey: Key.asked)
  }

  /// Reads the setting again.
  public func refresh() {
    let now = GlobeKey.systemUse(setting: system.read())
    if now != systemUse { systemUse = now }
    forgetIfChangedBack()
  }

  /// Sets "Press 🌐 key to" to "Do Nothing" and reports how that went.
  @discardableResult
  public func fix() -> GlobeKey.Outcome {
    refresh()
    guard interferes else { return .now }
    let before = systemUse
    let result = system.write(GlobeKey.SystemUse.nothing.rawValue)
    if result == .now {
      previousUse = before
      memory?.set(before.rawValue, forKey: Key.previous)
    }
    outcome = result
    refresh()
    return result
  }

  /// The user chose something else again in System Settings: what we remembered is out of date.
  private func forgetIfChangedBack() {
    guard previousUse != nil, interferes else { return }
    previousUse = nil
    memory?.removeObject(forKey: Key.previous)
    if outcome != nil { outcome = nil }
  }
}

/// Reading and changing the real setting.
///
/// The value lives in the preferences of `com.apple.HIToolbox` under `AppleFnUsageType`.
/// Programs that are already running keep their own copy of it, so writing the preference
/// alone only counts after the next login. macOS has a function that System Settings itself
/// uses to change the value everywhere at once (`TISUpdateFnUsageType`). It is not part of
/// the public system interface, so it is looked up by name at run time. On a macOS that
/// does not have it the change fails, and the app says how to make it by hand.
enum LiveSetting {
  private static var domain: CFString { "com.apple.HIToolbox" as CFString }
  private static var key: CFString { "AppleFnUsageType" as CFString }

  static func read() -> Int? {
    stored() ?? resolved()
  }

  static func write(_ value: Int) -> GlobeKey.Outcome {
    guard let update = function(named: "TISUpdateFnUsageType") else { return .failed }
    // One whole register for the value: right whether the system reads 32 or 64 bits of it.
    typealias Update = @convention(c) (Int) -> Void
    unsafeBitCast(update, to: Update.self)(value)
    // Taken when macOS itself now answers with the new value, or has it stored.
    guard resolved() == value || stored() == value else { return .failed }
    // The preference too, so the change lasts past the next login.
    if stored() != value {
      CFPreferencesSetAppValue(key, value as CFNumber, domain)
      CFPreferencesAppSynchronize(domain)
    }
    return .now
  }

  /// The value in the preferences, asked for afresh.
  private static func stored() -> Int? {
    CFPreferencesAppSynchronize(domain)
    return (CFPreferencesCopyAppValue(key, domain) as? NSNumber)?.intValue
  }

  /// What macOS does when the user never chose, when it will say.
  private static func resolved() -> Int? {
    guard let get = function(named: "TISGetFnUsageType") else { return nil }
    typealias Get = @convention(c) () -> Int32
    let value = Int(unsafeBitCast(get, to: Get.self)())
    return (0...3).contains(value) ? value : nil
  }

  /// Looks a function up in the part of macOS that owns the fn key (HIToolbox). `nil` when
  /// this macOS does not have it.
  private static func function(named name: String) -> UnsafeMutableRawPointer? {
    let path = "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox"
    guard let toolbox = dlopen(path, RTLD_LAZY) else { return nil }
    return dlsym(toolbox, name)
  }
}
