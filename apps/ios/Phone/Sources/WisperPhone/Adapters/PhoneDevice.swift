import SwiftUI
import WisperDomain
import WisperKeyboard
import WisperLive

#if canImport(UIKit)
  import UIKit
#endif

/// What the phone itself offers the screens, beyond what `AppModel` holds.
///
/// The real one talks to UIKit. `quiet` does nothing, for snapshots and tests.
struct PhoneDevice: Sendable {
  var clipboard: Clipboard
  /// Keeps the screen from dimming and locking while `true`.
  var keepAwake: @MainActor @Sendable (Bool) -> Void
  /// Shows this app's page in the Settings app.
  var openSettings: @MainActor @Sendable () -> Void
  /// Whether the Open Wisper keyboard is turned on in Settings. `nil` when that cannot be told.
  var keyboardIsOn: @MainActor @Sendable () -> Bool?
  /// Shows on the Lock Screen and in the Dynamic Island that a meeting is being recorded:
  /// its title and when it began. `nil` takes the notice away.
  var showRecording: @MainActor @Sendable ((title: String, startedAt: Date)?) async -> Void = { _ in }
  /// Runs work the person is waiting for even though the app has just left the screen.
  /// iOS gives it about half a minute before it puts the app to sleep.
  var finishInBackground: @MainActor @Sendable (@escaping @MainActor @Sendable () async -> Void) -> Void = {
    work in Task { await work() }
  }
  /// Whether a link's ticket was issued in this app's data folder just now (see `LinkTicket`).
  /// A ticket is used up by asking.
  var redeemTicket: @MainActor @Sendable (String?) -> Bool = { _ in false }

  static let live = PhoneDevice(
    clipboard: .system,
    keepAwake: { awake in
      #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = awake
      #endif
    },
    openSettings: { PhonePermissions.openAppSettings() },
    keyboardIsOn: {
      // iOS has no call for this. It does keep the list of the person's keyboards in the
      // defaults every app can read, each named by the bundle ID of its extension.
      guard let keyboards = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] else {
        return nil
      }
      let prefix = (Bundle.main.bundleIdentifier ?? "dev.openwisper.ios") + "."
      return keyboards.contains { $0.hasPrefix(prefix) }
    },
    showRecording: { recording in
      #if os(iOS)
        if let recording {
          await MeetingActivity.show(title: recording.title, startedAt: recording.startedAt)
        } else {
          await MeetingActivity.end()
        }
      #endif
    },
    finishInBackground: { work in
      #if canImport(UIKit)
        let hold = BackgroundHold()
        hold.begin()
        Task {
          await work()
          hold.end()
        }
      #else
        Task { await work() }
      #endif
    },
    // The keyboard writes its tickets into the folder it shares with the app.
    redeemTicket: { ticket in LinkTicket.redeem(ticket, in: SharedFolder().root) }
  )

  static let quiet = PhoneDevice(
    clipboard: Clipboard { _ in },
    keepAwake: { _ in },
    openSettings: {},
    keyboardIsOn: { nil }
  )
}

#if canImport(UIKit)
  /// Asks iOS for a little more time after the app leaves the screen, and gives it back.
  @MainActor
  private final class BackgroundHold {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin() {
      id = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { [weak self] in
        // Time is up: tell iOS so, or it ends the app.
        Task { @MainActor in self?.end() }
      }
    }

    func end() {
      guard id != .invalid else { return }
      UIApplication.shared.endBackgroundTask(id)
      id = .invalid
    }
  }
#endif

private struct PhoneDeviceKey: EnvironmentKey {
  static let defaultValue = PhoneDevice.quiet
}

extension EnvironmentValues {
  var phoneDevice: PhoneDevice {
    get { self[PhoneDeviceKey.self] }
    set { self[PhoneDeviceKey.self] = newValue }
  }
}
