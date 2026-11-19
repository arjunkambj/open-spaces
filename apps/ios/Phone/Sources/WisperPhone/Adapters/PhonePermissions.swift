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
  private let openSettings: @MainActor () -> Void

  /// - openSettings: shows this app's page in the Settings app. iOS asks about the
  ///   microphone only once; after a "no" that page is the only place to change it.
  public init(openSettings: @escaping @MainActor () -> Void = PhonePermissions.openAppSettings) {
    self.openSettings = openSettings
  }

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
    case .denied: openSettings()
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
