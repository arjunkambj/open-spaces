import AppKit
import ServiceManagement

/// Opens Open Wisper when the user logs in to their Mac.
///
/// Nothing here throws: when macOS says no, the status says why.
@MainActor
public enum LaunchAtLogin {
  public enum Status: Sendable, Equatable {
    case on
    case off
    /// Registered, but the user has to allow it in System Settings > General > Login Items.
    case needsApproval
  }

  public static var status: Status {
    switch SMAppService.mainApp.status {
    case .enabled: .on
    case .requiresApproval: .needsApproval
    default: .off
    }
  }

  /// Turns opening at login on or off and returns the status afterwards.
  /// Check the result: macOS can refuse, for example when the app is run
  /// from a disk image or the user has blocked it in Login Items.
  @discardableResult
  public static func set(_ enabled: Bool) -> Status {
    let service = SMAppService.mainApp
    do {
      if enabled {
        if service.status != .enabled { try service.register() }
      } else if service.status != .notRegistered {
        try service.unregister()
      }
    } catch {
      // Nothing useful to do with the error: the status below tells the story.
    }
    return status
  }

  /// Opens System Settings at Login Items, for `needsApproval`.
  public static func openSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
