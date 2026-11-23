import AppKit

/// The system clipboard, for every screen.
@MainActor
enum ScreenClipboard {
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  /// The text on the clipboard, for a "Paste" button.
  static func text() -> String? {
    NSPasteboard.general.string(forType: .string)
  }
}
