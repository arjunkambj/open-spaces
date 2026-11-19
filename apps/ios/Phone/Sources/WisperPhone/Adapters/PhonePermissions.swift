import AVFAudio
import Foundation
import WisperDomain

#if canImport(UIKit)
  import UIKit
#endif

/// The system permissions Open Wisper needs on an iPhone: the microphone, and nothing else.
///
/// The other permissions in `Permission` belong to the Mac. They report `.granted` here,
/// meaning "nothing to ask for", so no screen holds the person up over them.
@MainActor
public final class PhonePermissions: Permissions {
  public let needed: [Permission] = [.microphone]

  public init() {}

  public func status(_ permission: Permission) -> PermissionStatus {
    guard permission == .microphone else { return .granted }
    switch AVAudioApplication.shared.recordPermission {
    case .granted: return .granted
    case .denied: return .denied
    case .undetermined: return .notDetermined
    @unknown default: return .notDetermined
    }
  }

  @discardableResult
  public func request(_ permission: Permission) async -> PermissionStatus {
    guard permission == .microphone else { return .granted }
    switch status(.microphone) {
    case .granted: break
    case .notDetermined: _ = await AVAudioApplication.requestRecordPermission()
    // iOS asks only once. After a "no", the app's page in Settings is the only place to change it.
    case .denied: Self.openAppSettings()
    }
    return status(.microphone)
  }

  /// Opens this app's page in the Settings app.
  public static func openAppSettings() {
    #if canImport(UIKit)
      guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
      UIApplication.shared.open(url)
    #endif
  }
}
