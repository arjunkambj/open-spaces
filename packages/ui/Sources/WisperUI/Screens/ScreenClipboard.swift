import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
  import UniformTypeIdentifiers
#endif

/// The system clipboard, for every screen.
@MainActor
enum ScreenClipboard {
  /// What kind of text is being copied.
  enum Kind: Sendable {
    /// Something the person said, or that was said in a meeting. On iPhone it stays on this
    /// device (it is not handed to the person's other devices) and goes away after a while.
    case personal
    /// A command or a path: nothing private.
    case plain
  }

  /// How long personal text stays on an iPhone's clipboard, in seconds.
  static let personalLifetime: TimeInterval = 600

  static func copy(_ text: String, as kind: Kind) {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #elseif canImport(UIKit)
      switch kind {
      case .personal:
        UIPasteboard.general.setItems(
          [[UTType.utf8PlainText.identifier: text]],
          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(personalLifetime)]
        )
      case .plain:
        UIPasteboard.general.string = text
      }
    #endif
  }

  /// The text on the clipboard, for a "Paste" button.
  static func text() -> String? {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
      NSPasteboard.general.string(forType: .string)
    #elseif canImport(UIKit)
      UIPasteboard.general.string
    #else
      nil
    #endif
  }
}
