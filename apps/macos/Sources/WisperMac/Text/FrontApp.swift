import AppKit
import ApplicationServices

/// Questions asked of another app through the Accessibility API, and key
/// presses sent to it. None of this needs the main thread, and every question
/// gives up after `timeout`, so an app that has stopped responding cannot
/// hold up a dictation.
enum FrontApp {
  static let timeout: Float = 0.3

  enum Selection: Sendable, Equatable {
    /// The focused field answered. Empty means nothing is selected.
    case text(String)
    /// The app would not say (many web and Electron apps).
    case unknown
  }

  /// The selected text in the focused field of the app with `pid`.
  static func selection(pid: pid_t) -> Selection {
    let app = element(forApp: pid)
    guard let focused = child(of: app, "AXFocusedUIElement") else { return .unknown }
    guard let text = string(of: focused, "AXSelectedText") else { return .unknown }
    return .text(text)
  }

  /// The title of the front window of the app with `pid`, and the address of
  /// the page it shows when the app offers it (Safari does).
  static func frontWindow(pid: pid_t) -> (title: String?, url: String?) {
    let app = element(forApp: pid)
    guard let window = child(of: app, "AXFocusedWindow") ?? child(of: app, "AXMainWindow") else {
      return (nil, nil)
    }
    let title = string(of: window, "AXTitle")
    var url = string(of: window, "AXDocument")
    if url == nil, let value = attribute(of: window, "AXURL") { url = (value as? URL)?.absoluteString }
    return (title, url)
  }

  private static func element(forApp pid: pid_t) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, timeout)
    return app
  }

  private static func attribute(of element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }

  private static func string(of element: AXUIElement, _ name: String) -> String? {
    attribute(of: element, name) as? String
  }

  private static func child(of element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(of: element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    let child = unsafeDowncast(value, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(child, timeout)
    return child
  }

  // MARK: - Key presses

  /// Presses ⌘ and the key at `keyCode` in the app that has the keyboard.
  /// The press is marked as ours, so `ShortcutMonitor` does not react to it,
  /// and carries only ⌘ even if the user is still holding other keys.
  static func pressCommand(keyCode: UInt16) {
    let source = CGEventSource(stateID: .combinedSessionState)
    source?.userData = KeyboardTap.ownEventTag
    for isDown in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
        continue
      }
      event.flags = .maskCommand
      event.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.ownEventTag)
      event.post(tap: .cgSessionEventTap)
    }
  }
}
