import Foundation
import SpacesDomain

#if canImport(UIKit)
  import UIKit
  import UniformTypeIdentifiers
#endif

/// A place to put text so the person can paste it into another app.
public struct Clipboard: Sendable {
  /// Replaces what is on the clipboard with `text`.
  public var write: @MainActor @Sendable (String) -> Void

  public init(write: @escaping @MainActor @Sendable (String) -> Void) {
    self.write = write
  }

  /// How long text stays on the phone's clipboard before iOS clears it, in seconds.
  public static let lifetime: TimeInterval = 600

  /// The clipboard every app on the phone shares. The text stays on this phone (it is not
  /// handed to the person's other devices) and iOS clears it after `lifetime`: dictated
  /// text can be private, and a clipboard is read by whatever app is opened next.
  /// On a Mac, where this package is only built for its snapshots, it does
  /// nothing: the person's clipboard is theirs.
  public static let system = Clipboard { text in
    #if canImport(UIKit)
      UIPasteboard.general.setItems(
        [[UTType.utf8PlainText.identifier: text]],
        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(lifetime)]
      )
    #endif
  }
}

/// Where dictated text goes on an iPhone.
///
/// An iPhone app cannot type into another app, so "insert" means: put the text on the
/// clipboard, ready to paste. The keyboard extension offers the same text from the
/// library with its Insert latest key.
public actor ClipboardTextTarget: TextTarget {
  private let clipboard: Clipboard

  public init(clipboard: Clipboard) {
    self.clipboard = clipboard
  }

  /// The phone cannot see which app the text is for, so it is always "everything else".
  public func context() -> DictationContext {
    DictationContext(category: .other)
  }

  /// There is no selection to read on the phone.
  public func selectedText() -> String? { nil }

  public func insert(_ text: String) async {
    await clipboard.write(text)
  }
}
