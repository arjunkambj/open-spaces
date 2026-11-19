import SwiftUI
import WisperDomain
import WisperEngine

/// Every setting, in sections. Reads `AppModel` from the environment.
/// - shortcuts: the platform's keyboard-shortcut editor (macOS), or `nil` to leave that section out.
/// - onClose: called by the close button; `nil` hides the button.
public struct SettingsScreen: View {
  private let shortcuts: AnyView?
  private let onClose: (() -> Void)?

  public init(shortcuts: AnyView? = nil, onClose: (() -> Void)? = nil) {
    self.shortcuts = shortcuts
    self.onClose = onClose
  }

  public var body: some View {
    // CONTRACT STUB: the screen builder replaces this body.
    Text("SettingsScreen")
  }
}
