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

  /// Remembers what the system cannot be asked about.
  private let defaults = UserDefaults.standard
  private static let askedAccessibility = "permissions.accessibility.asked"

  public init() {}

  public func status(_ permission: Permission) -> PermissionStatus {
    switch permission {
    case .microphone:
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized: return .granted
      case .notDetermined: return .notDetermined
      default: return .denied
      }
    case .accessibility:
      // The system only says yes or no. "No" before we ever asked means the
      // user has not been shown anything yet.
      if AXIsProcessTrusted() { return .granted }
      return defaults.bool(forKey: Self.askedAccessibility) ? .denied : .notDetermined
    case .systemAudio:
      // 0: allowed, 1: refused, 2: never asked.
      switch SystemPermissionLibrary.preflight(SystemPermissionLibrary.audioCapture, nil) {
      case 0: return .granted
      case 2: return .notDetermined
      default: return .denied
      }
    }
  }

  @discardableResult
  public func request(_ permission: Permission) async -> PermissionStatus {
    switch (permission, status(permission)) {
    case (_, .granted):
      break
    case (.microphone, .notDetermined):
      _ = await AVCaptureDevice.requestAccess(for: .audio)
    case (.accessibility, .notDetermined):
      // Shows the system's "would like to control this computer" alert, which
      // has a button that opens the right pane, and adds the app to the list.
      defaults.set(true, forKey: Self.askedAccessibility)
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    case (.systemAudio, .notDetermined):
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        SystemPermissionLibrary.request(SystemPermissionLibrary.audioCapture, nil) { _ in
          continuation.resume()
        }
      }
    default:
      // The system will not ask twice. The user has to flip the switch.
      openSettings(for: permission)
    }
    return status(permission)
  }

  /// Opens System Settings at the pane where `permission` is switched on.
  public func openSettings(for permission: Permission) {
    let anchor =
      switch permission {
      case .microphone: "Privacy_Microphone"
      case .accessibility: "Privacy_Accessibility"
      case .systemAudio: "Privacy_AudioCapture"
      }
    let pane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
    guard let url = URL(string: pane) else { return }
    NSWorkspace.shared.open(url)
  }
}

/// The system's own permission library, for the one permission macOS has no public call
/// for: recording the computer's sound. Its functions are private, so they are looked up
/// by name at run time. A macOS that does not have them stops the app with a message
/// that says so.
private enum SystemPermissionLibrary {
  typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
  typealias Request =
    @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void)
    -> Void

  static var audioCapture: CFString { "kTCCServiceAudioCapture" as CFString }

  /// Says whether the permission is given, without showing anything.
  static let preflight = unsafeBitCast(symbol("TCCAccessPreflight"), to: Preflight.self)
  /// Shows the system prompt and calls back with the answer.
  static let request = unsafeBitCast(symbol("TCCAccessRequest"), to: Request.self)

  private static func symbol(_ name: String) -> UnsafeMutableRawPointer {
    let path = "/System/Library/PrivateFrameworks/TCC.framework/TCC"
    guard let library = dlopen(path, RTLD_NOW), let symbol = dlsym(library, name) else {
      fatalError("This macOS has no \(name), which Open Wisper needs to ask about recording system audio.")
    }
    return symbol
  }
}
