import AppKit
import ApplicationServices
import WisperDomain

/// Types dictated text into whatever app the user is working in.
///
/// How the app is chosen:
/// - `context()` picks the target: the app in front. When that is Open Wisper
///   itself and no text field of ours has the cursor (the user clicked the
///   pill or the hub), it is the app that was in front just before.
/// - `insert(_:)` types where the cursor is now. If Open Wisper is in front
///   without a text field of its own in use, the target is brought forward
///   first, so text never lands in our own windows by accident.
///
/// Text goes in by pasting: the clipboard is borrowed, ⌘V is pressed, and the
/// user's clipboard is put back half a second later. This works the same in
/// native, web and Electron apps, and replaces the selection.
///
/// Needs the Accessibility permission. Without it `insert` throws,
/// `selectedText` returns nil and browser pages are not recognised.
@MainActor
public final class MacTextTarget: TextTarget {
  /// How long the dictated text stays on the clipboard before the user's own
  /// contents come back. Slow apps read the clipboard a moment after ⌘V.
  private static let restoreDelay: Duration = .milliseconds(500)

  private let clipboard: BorrowedPasteboard
  private let ownPID = ProcessInfo.processInfo.processIdentifier
  /// The last app in front that was not Open Wisper.
  private var lastOtherApp: NSRunningApplication?
  /// The app the current dictation is for, set by `context()`.
  private var target: NSRunningApplication?
  private var activation: WorkspaceObservation?
  private var restore: Task<Void, Never>?

  /// Stops observing when it goes away, so the target needs no clean-up of its own.
  private final class WorkspaceObservation: @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) { self.token = token }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(token) }
  }

  public init() {
    clipboard = BorrowedPasteboard(.general)
    noteFrontApp()
    let token = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.noteFrontApp() }
    }
    activation = WorkspaceObservation(token)
  }

  // MARK: - TextTarget

  public func context() async -> DictationContext {
    noteFrontApp()
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
    noteFrontApp()
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
      return await copySelection()
    }
  }

  public func insert(_ text: String) async throws {
    guard AXIsProcessTrusted() else { throw WisperError.permissionDenied(.accessibility) }
    guard !text.isEmpty else { return }
    try await bringTargetForward()
    target = nil
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

  private func noteFrontApp() {
    guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID else {
      return
    }
    lastOtherApp = front
  }

  /// The app the user is typing in right now.
  private func currentTarget() -> NSRunningApplication? {
    if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
      return front
    }
    if ownTextView() != nil { return .current }
    if let lastOtherApp, !lastOtherApp.isTerminated { return lastOtherApp }
    return nil
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

  /// Makes sure a press of ⌘V will land in the right place.
  private func bringTargetForward() async throws {
    if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID { return }
    if ownTextView() != nil { return }
    let candidate = [target, lastOtherApp].compactMap { $0 }.first {
      !$0.isTerminated && $0.processIdentifier != ownPID
    }
    guard let app = candidate else { throw WisperError.notFound("The app you were typing in") }
    NSApp?.yieldActivation(to: app)
    app.activate()
    for _ in 0..<50 {
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
        // Give the app a moment to hand the keyboard to its window.
        try? await Task.sleep(for: .milliseconds(60))
        return
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    throw WisperError.notFound("The app you were typing in")
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
    clipboard.giveBack()
    guard let copied, !copied.isEmpty else { return nil }
    return copied
  }
}
