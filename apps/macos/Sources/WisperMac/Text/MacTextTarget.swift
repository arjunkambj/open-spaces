import AppKit
import ApplicationServices
import WisperDomain

/// Types dictated text into whatever app the user is working in.
///
/// Where the text goes:
/// - Into the app in front, where the cursor is now. No other app is ever
///   brought forward to receive it.
/// - When Open Wisper itself is in front, into the text field of ours that
///   has the cursor. When none has, the text is put on the clipboard and
///   left there for the user to paste, and `onCopied` is called.
///
/// Text goes into an app by pasting: the clipboard is borrowed, ⌘V is
/// pressed, and the user's clipboard is put back a moment later. This works
/// the same in native, web and Electron apps, and replaces the selection.
///
/// Typing into another app needs the Accessibility permission. Without it
/// `insert` throws, `selectedText` returns nil and browser pages are not
/// recognised.
@MainActor
public final class MacTextTarget: TextTarget {
  /// How long the dictated text stays on the clipboard before the user's own
  /// contents come back. An app that is busy reads the clipboard well after
  /// ⌘V was pressed; put back too soon, it would paste the old contents.
  private static let restoreDelay: Duration = .milliseconds(1500)
  /// How long a copy we asked for may still turn up after we stopped waiting for it.
  private static let lateCopyTime: TimeInterval = 1.5

  /// Called when text was put on the clipboard instead of typed, because
  /// Open Wisper was in front with no text field of its own in use.
  public var onCopied: (@MainActor () -> Void)?

  private let clipboard: BorrowedPasteboard
  private let ownPID = ProcessInfo.processInfo.processIdentifier
  /// Whether Open Wisper is the app in front. Tests answer this themselves.
  private let isInFront: @MainActor () -> Bool
  /// The app the current dictation is for, set by `context()`.
  private var target: NSRunningApplication?
  private var restore: Task<Void, Never>?

  public convenience init() {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    self.init(clipboard: BorrowedPasteboard(.general)) {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID
    }
  }

  init(clipboard: BorrowedPasteboard, isInFront: @escaping @MainActor () -> Bool) {
    self.clipboard = clipboard
    self.isInFront = isInFront
  }

  // MARK: - TextTarget

  public func context() async -> DictationContext {
    let app = currentTarget()
    target = app
    guard let app else { return DictationContext() }
    let bundleID = app.bundleIdentifier
    var window: (title: String?, url: String?) = (nil, nil)
    if AppCatalog.isBrowser(bundleID), AXIsProcessTrusted() {
      let pid = app.processIdentifier
      window = await Task.detached { FrontApp.frontWindow(pid: pid) }.value
    }
    return DictationContext(
      appName: app.localizedName,
      bundleID: bundleID,
      category: AppCatalog.category(bundleID: bundleID, windowTitle: window.title, url: window.url)
    )
  }

  public func selectedText() async -> String? {
    guard let app = target ?? currentTarget() else { return nil }
    if app.processIdentifier == ownPID { return ownSelection() }
    guard AXIsProcessTrusted() else { return nil }
    let pid = app.processIdentifier
    switch await Task.detached(operation: { FrontApp.selection(pid: pid) }).value {
    case .text(let text):
      return text.isEmpty ? nil : text
    case .unknown:
      // The app would not say. Ask it to copy instead, but only if it is the
      // app in front: a copy sent anywhere else would do who knows what.
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
      guard let copied = await copySelection() else { return nil }
      return Self.isWholeLineCopy(copied, bundleID: app.bundleIdentifier) ? nil : copied
    }
  }

  public func insert(_ text: String) async throws {
    guard !text.isEmpty else { return }
    target = nil
    if isInFront(), ownTextView() == nil {
      // Our own window is in front and nothing in it takes text. Pasting would land nowhere,
      // and bringing another app forward to paste there is not ours to decide.
      restore?.cancel()
      clipboard.keep(text)
      onCopied?()
      return
    }
    guard AXIsProcessTrusted() else { throw WisperError.permissionDenied(.accessibility) }
    await waitForModifiersToLift()
    restore?.cancel()
    clipboard.borrow()
    clipboard.place(text)
    FrontApp.pressCommand(keyCode: KeyboardLayout.keyCode(forCommand: "v") ?? KeyCombo.KeyCode.v)
    restore = Task { [clipboard] in
      try? await Task.sleep(for: Self.restoreDelay)
      guard !Task.isCancelled else { return }
      clipboard.giveBack()
    }
  }

  // MARK: - Which app

  /// The app the user is typing in right now.
  private func currentTarget() -> NSRunningApplication? {
    isInFront() ? .current : NSWorkspace.shared.frontmostApplication
  }

  /// The text view of ours that has the cursor, if one does.
  private func ownTextView() -> NSTextView? {
    guard let app = NSApp, app.isActive else { return nil }
    return app.keyWindow?.firstResponder as? NSTextView
  }

  private func ownSelection() -> String? {
    guard let view = ownTextView(), let range = Range(view.selectedRange(), in: view.string) else {
      return nil
    }
    let text = String(view.string[range])
    return text.isEmpty ? nil : text
  }

  /// A shortcut such as ⌃⌘V can ask for a paste while its keys are still
  /// down, and ⌃, ⌥ or ⇧ held together with ⌘V mean something else to many
  /// apps. Waits for them to be let go, for at most 400 ms.
  private func waitForModifiersToLift() async {
    let inTheWay: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
    for _ in 0..<20 {
      if CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: inTheWay) { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  // MARK: - Copy fallback

  /// Reads the selection by pressing ⌘C and looking at the clipboard, then
  /// puts the user's clipboard back. Waits at most 300 ms for the copy.
  private func copySelection() async -> String? {
    await waitForModifiersToLift()
    restore?.cancel()
    clipboard.borrow()
    let before = clipboard.changeCount
    FrontApp.pressCommand(keyCode: KeyboardLayout.keyCode(forCommand: "c") ?? 8)
    var copied: String?
    for _ in 0..<15 {
      try? await Task.sleep(for: .milliseconds(20))
      if clipboard.changeCount != before {
        copied = clipboard.takeCopiedText()
        break
      }
    }
    guard let copied else {
      // Nothing yet. A slow app may still copy in a moment: hold on to the user's clipboard
      // until then, so that late copy is undone instead of staying on it.
      clipboard.expectCopy(for: Self.lateCopyTime)
      restore = Task { [clipboard] in
        try? await Task.sleep(for: .seconds(Self.lateCopyTime))
        guard !Task.isCancelled else { return }
        clipboard.giveBack()
      }
      return nil
    }
    clipboard.giveBack()
    return copied.isEmpty ? nil : copied
  }

  /// Whether what ⌘C gave is a line the editor copied by itself because nothing was selected.
  ///
  /// Code editors copy the whole line the cursor is on when ⌘C is pressed with no selection.
  /// Taken for a selection, that line would be rewritten and pasted at the cursor, next to
  /// the line it came from. So in those editors one line that ends in a line break counts
  /// as nothing selected. (A line picked with a triple click looks the same and is passed
  /// over too; selecting it without its line break works.)
  nonisolated static func isWholeLineCopy(_ copied: String, bundleID: String?) -> Bool {
    guard AppCatalog.copiesLineWithoutSelection(bundleID), let last = copied.last, last.isNewline else {
      return false
    }
    return !copied.dropLast().contains(where: \.isNewline)
  }
}
