import SwiftUI
import WisperDomain
import WisperEngine
import WisperMac
import WisperUI

/// Says that macOS reacts to the fn (Globe) key too, and offers to switch that off with
/// one click. Shows nothing when there is nothing to say, so it can always be in a screen.
///
/// Reads `AppModel` and `MacControls` from the environment, and looks at the Mac's setting
/// again every second while it is on screen: once the key is free, the hint goes away.
struct GlobeKeyHint: View {
  /// What there is to say.
  enum Stage: Equatable {
    case nothing
    /// macOS does this on fn, and fn is part of a shortcut.
    case conflict(GlobeKey.SystemUse)
    /// The fix is saved, but macOS only follows it after the next login.
    case afterLogin
    /// macOS would not take the change: the user has to do it by hand.
    case failed(GlobeKey.SystemUse)
  }

  @Environment(AppModel.self) private var model
  @Environment(MacControls.self) private var controls
  /// A fixed stage for still pictures; `nil` follows the Mac.
  var preview: Stage?

  var body: some View {
    Group {
      switch preview ?? Self.stage(of: controls.globeKey, shortcuts: model.settings.shortcuts) {
      case .nothing:
        EmptyView()
      case .conflict(let use):
        Banner(.warning, title: "macOS also reacts to the fn key", message: Self.message(for: use)) {
          Button(MacControls.globeKeyFixTitle(for: use)) { controls.globeKey.fix() }
            .buttonStyle(.wisper(.tertiary, size: .small))
        }
      case .afterLogin:
        Banner(
          title: "Almost done",
          message: "macOS leaves the fn key to Open Wisper once you log out of your Mac and back in."
        )
      case .failed(let use):
        Banner(
          .warning,
          title: "macOS did not take the change",
          message: "In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”. " + Self.message(for: use)
        ) {
          Button("Open Keyboard settings") { GlobeKey.openSettings() }
            .buttonStyle(.wisper(.tertiary, size: .small))
        }
      }
    }
    .task {
      guard preview == nil else { return }
      while !Task.isCancelled {
        controls.globeKey.refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  static func stage(of setting: GlobeKeySetting, shortcuts: [ShortcutAction: KeyCombo]) -> Stage {
    if setting.needsFix(for: shortcuts) {
      return setting.outcome == .failed ? .failed(setting.systemUse) : .conflict(setting.systemUse)
    }
    if setting.outcome == .afterLogin, GlobeKey.isUsed(by: shortcuts) { return .afterLogin }
    return .nothing
  }

  static func message(for use: GlobeKey.SystemUse) -> String {
    switch use {
    case .changeInputSource: "Right now it also switches the keyboard language when you dictate."
    case .startDictation: "Right now it can also start the Mac’s own dictation when you dictate."
    case .nothing, .showEmoji, .systemDefault: "Right now it can also open the emoji picker when you dictate."
    }
  }
}

/// One quiet line for Settings: what Open Wisper changed about the fn key, and how to change it back.
/// Shows nothing when Open Wisper changed nothing.
struct GlobeKeyUndoNote: View {
  @Environment(MacControls.self) private var controls
  /// A fixed earlier choice for still pictures; `nil` follows what was remembered.
  var preview: GlobeKey.SystemUse?

  var body: some View {
    if let before = preview ?? controls.globeKey.previousUse {
      HStack(alignment: .firstTextBaseline, spacing: Wisper.Space.m) {
        Text(Self.text(before: before))
          .wisperText(.caption)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("Open Keyboard settings") { GlobeKey.openSettings() }
          .buttonStyle(.wisper(.ghost, size: .small))
      }
    }
  }

  static func text(before: GlobeKey.SystemUse) -> String {
    "Open Wisper set the Mac’s “Press 🌐 key to” to “Do Nothing” for you. Before, it was “\(before.title)”. "
      + "You can change it back in Keyboard settings."
  }
}
