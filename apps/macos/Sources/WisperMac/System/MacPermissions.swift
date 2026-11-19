import AVFoundation
import AppKit
import ApplicationServices
import WisperDomain

/// The system permissions Open Wisper needs on a Mac.
///
/// - **Microphone**: to hear the user. The system shows a prompt once.
/// - **Accessibility**: to see the global shortcuts and to type into other
///   apps. One switch covers both; Input Monitoring is not needed. There is
///   no prompt that grants it: the user turns the app on in System Settings.
/// - **System audio**: to record the other side of a call in meetings. The
///   system shows a prompt once.
///
/// `status` never shows a prompt, so it is safe to poll while the user is in
/// System Settings.
@MainActor
public final class MacPermissions: Permissions {
  public let needed: [Permission] = [.microphone, .accessibility, .systemAudio]

  private let defaults: UserDefaults
  private let systemAudio: SystemAudioAccess

  private enum Key {
    static let askedAccessibility = "permissions.accessibility.asked"
    static let systemAudioWorked = "permissions.systemAudio.worked"
  }

  /// `defaults` remembers what the system cannot be asked about.
  public convenience init(defaults: UserDefaults = .standard) {
    self.init(defaults: defaults, systemAudio: .system)
  }

  init(defaults: UserDefaults, systemAudio: SystemAudioAccess) {
    self.defaults = defaults
    self.systemAudio = systemAudio
  }

  public func status(_ permission: Permission) -> PermissionStatus {
    switch permission {
    case .microphone:
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized: .granted
      case .notDetermined: .notDetermined
      default: .denied
      }
    case .accessibility:
      // The system only says yes or no. "No" before we ever asked means the
      // user has not been shown anything yet.
      if AXIsProcessTrusted() {
        .granted
      } else {
        defaults.bool(forKey: Key.askedAccessibility) ? .denied : .notDetermined
      }
    case .systemAudio:
      // macOS has no public way to ask about this one. The same private
      // check Apple's own apps use is tried first; if a future macOS removes
      // it, the answer is what the last real recording found.
      if let known = systemAudio.status() {
        known
      } else if let worked = defaults.object(forKey: Key.systemAudioWorked) as? Bool {
        worked ? .granted : .denied
      } else {
        .notDetermined
      }
    }
  }

  @discardableResult
  public func request(_ permission: Permission) async -> PermissionStatus {
    switch (permission, status(permission)) {
    case (_, .granted):
      break
    case (.microphone, .notDetermined) where Self.hasUsageText("NSMicrophoneUsageDescription"):
      _ = await AVCaptureDevice.requestAccess(for: .audio)
    case (.accessibility, .notDetermined):
      // Shows the system's "would like to control this computer" alert, which
      // has a button that opens the right pane, and adds the app to the list.
      defaults.set(true, forKey: Key.askedAccessibility)
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    case (.systemAudio, .notDetermined) where Self.hasUsageText("NSAudioCaptureUsageDescription"):
      if await systemAudio.request() == nil { openSettings(for: permission) }
    default:
      // The system will not ask twice. The user has to flip the switch.
      openSettings(for: permission)
    }
    return status(permission)
  }

  /// Opens System Settings at the pane where `permission` is switched on.
  public func openSettings(for permission: Permission) {
    for url in Self.settingsURLs(for: permission) where NSWorkspace.shared.open(url) { return }
  }

  /// Call after a meeting recording that included system audio, with whether
  /// the computer's sound was really captured. Keeps `status(.systemAudio)`
  /// truthful on a macOS where it cannot be read directly.
  public func noteSystemAudioCapture(worked: Bool) {
    defaults.set(worked, forKey: Key.systemAudioWorked)
  }

  /// The links that open the pane for `permission`, best first.
  static func settingsURLs(for permission: Permission) -> [URL] {
    let anchor =
      switch permission {
      case .microphone: "Privacy_Microphone"
      case .accessibility: "Privacy_Accessibility"
      case .systemAudio: "Privacy_AudioCapture"
      }
    return ["com.apple.settings.PrivacySecurity.extension", "com.apple.preference.security"].compactMap {
      URL(string: "x-apple.systempreferences:\($0)?\(anchor)")
    }
  }

  /// The system ends an app that asks for a permission without having said
  /// why in its Info.plist. That text is missing when run outside the bundle.
  private static func hasUsageText(_ key: String) -> Bool {
    Bundle.main.object(forInfoDictionaryKey: key) != nil
  }
}

/// How to ask the system about recording the computer's sound.
///
/// macOS has no public call for this permission. `system` uses the private
/// functions in the system's own permission library, looked up by name at run
/// time so that their absence is survivable: every answer can be "don't know".
struct SystemAudioAccess: Sendable {
  /// The status, or nil when the system cannot be asked.
  var status: @Sendable () -> PermissionStatus?
  /// Shows the system prompt and waits for the answer. Nil when it cannot.
  var request: @Sendable () async -> Bool?

  static let system = SystemAudioAccess(
    status: {
      guard let preflight = SystemPermissionLibrary.preflight else { return nil }
      // 0: allowed, 1: refused, 2: never asked.
      switch preflight(SystemPermissionLibrary.audioCapture, nil) {
      case 0: return .granted
      case 1: return .denied
      case 2: return .notDetermined
      default: return nil
      }
    },
    request: {
      guard let request = SystemPermissionLibrary.request else { return nil }
      return await withCheckedContinuation { continuation in
        request(SystemPermissionLibrary.audioCapture, nil) { granted in
          continuation.resume(returning: granted)
        }
      }
    }
  )
}

private enum SystemPermissionLibrary {
  typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
  typealias Request =
    @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void)
    -> Void

  static var audioCapture: CFString { "kTCCServiceAudioCapture" as CFString }

  static let preflight: Preflight? = symbol("TCCAccessPreflight").map {
    unsafeBitCast($0, to: Preflight.self)
  }
  static let request: Request? = symbol("TCCAccessRequest").map { unsafeBitCast($0, to: Request.self) }

  private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
    guard let library = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW) else {
      return nil
    }
    return dlsym(library, name)
  }
}
