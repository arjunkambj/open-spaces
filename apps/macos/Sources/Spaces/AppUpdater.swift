import AppKit
import Sparkle

/// Looks for new versions of Spaces and installs one when the person says yes.
///
/// It checks by itself about once a day, and at once when asked with `checkNow()`. A download
/// is only installed when its signature matches the key inside this copy of the app.
///
/// The work is done by Sparkle, the updater most Mac apps outside the App Store use. This is
/// the only file that knows about it.
@MainActor
final class AppUpdater {
  /// The version of an update that was found by a check the person did not ask for and
  /// that still waits for their answer, such as "0.2.0". `nil` when there is none.
  private(set) var waitingVersion: String?

  private let controller: SPUStandardUpdaterController
  /// Kept here because Sparkle does not keep it alive itself.
  private let reminders: Reminders

  /// Starts looking for updates.
  /// Returns `nil` when this copy of the app does not update itself: the build script
  /// leaves the address to ask for updates out of a build made without the project's keys.
  init?() {
    guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
    let reminders = Reminders()
    self.reminders = reminders
    controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: reminders
    )
    reminders.updater = self
  }

  /// Whether a check can start right now. False while one is already under way.
  var canCheck: Bool { controller.updater.canCheckForUpdates }

  /// Looks for a new version now and shows what it finds. When an update is already
  /// waiting for an answer, brings its window to the front.
  func checkNow() {
    // Sparkle makes the app the front one for a check the person asked for, so its window
    // does not open behind other apps.
    controller.checkForUpdates(nil)
  }

  // MARK: - Making sure an update is noticed

  // A menu bar app has no Dock icon, so a window that opens behind other apps is easy to
  // miss. While an update is on screen the app shows a Dock icon, with a badge when the
  // person did not ask for the check, and the menus offer the update by its version.

  fileprivate func willShow(version: String, askedFor: Bool) {
    DockIcon.show(for: .update)
    guard !askedFor else { return }
    waitingVersion = version
    NSApp.dockTile.badgeLabel = "1"
  }

  fileprivate func wasNoticed() {
    NSApp.dockTile.badgeLabel = nil
  }

  fileprivate func finished() {
    waitingVersion = nil
    NSApp.dockTile.badgeLabel = nil
    DockIcon.hide(for: .update)
  }
}

/// Hears from Sparkle when an update is shown and when the person is done with it.
@MainActor
private final class Reminders: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
  weak var updater: AppUpdater?

  /// Tells Sparkle this app points out an update itself, as an app with no Dock icon must.
  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    updater?.willShow(version: update.displayVersionString, askedFor: state.userInitiated)
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    updater?.wasNoticed()
  }

  func standardUserDriverWillFinishUpdateSession() {
    updater?.finished()
  }
}

/// Whether the app has a Dock icon. It has one while something that needs it is on
/// screen, and is a menu bar app with no Dock icon the rest of the time.
@MainActor
enum DockIcon {
  enum Reason {
    /// The main window is open.
    case hub
    /// An update is being shown.
    case update
  }

  private static var reasons: Set<Reason> = []

  static func show(for reason: Reason) {
    reasons.insert(reason)
    if NSApp.activationPolicy() != .regular {
      NSApp.setActivationPolicy(.regular)
    }
  }

  static func hide(for reason: Reason) {
    reasons.remove(reason)
    if reasons.isEmpty, NSApp.activationPolicy() != .accessory {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
