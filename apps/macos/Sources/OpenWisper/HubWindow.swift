import AppKit
import SwiftUI
import WisperEngine
import WisperMacUI

/// The main window. Made the first time it is shown and kept after it is closed,
/// so opening it again is instant and it comes back where it was.
///
/// While it is open the app has a Dock icon and a menu bar; when it closes the
/// app goes back to living in the menu bar only.
@MainActor
final class HubWindow: NSObject, NSWindowDelegate {
  let navigation: HubNavigation
  private let model: AppModel
  private let controls: MacControls
  private let remembersFrame: Bool
  private var window: NSWindow?

  private static let defaultSize = CGSize(width: 1180, height: 780)
  private static let minimumSize = CGSize(width: 900, height: 600)
  /// First-run setup is a small window; the hub takes its place when setup is done.
  private static let setupSize = CGSize(width: 720, height: 560)
  private static let frameName = "Hub"
  private var sizeWatch: Watch<Bool>?

  init(model: AppModel, controls: MacControls, navigation: HubNavigation, remembersFrame: Bool) {
    self.model = model
    self.controls = controls
    self.navigation = navigation
    self.remembersFrame = remembersFrame
  }

  var isOpen: Bool { window?.isVisible ?? false }

  func show() {
    let window = window ?? makeWindow()
    self.window = window
    DockIcon.show(for: .hub)
    window.makeKeyAndOrderFront(nil)
    // The Dock icon and the menu bar only turn up when the app is activated a turn later.
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    }
  }

  func close() {
    window?.performClose(nil)
  }

  /// Brings the window forward and asks a yes-or-no question on it. Returns whether the
  /// answer was yes. Return picks no, so a key press meant for something else never says yes.
  func confirm(_ question: String, yes: String, no: String) async -> Bool {
    show()
    guard let window else { return false }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = question
    alert.addButton(withTitle: no)
    alert.addButton(withTitle: yes)
    return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: Self.defaultSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Open Wisper"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.minSize = Self.minimumSize
    window.tabbingMode = .disallowed
    // Asked for from the menu bar or the pill, the window comes to the desktop the person is on.
    window.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
    window.delegate = self
    window.contentView = NSHostingView(
      rootView: HubView(navigation: navigation)
        .environment(model)
        .environment(controls)
    )
    sizeWatch = Watch({ [model] in model.settings.isOnboarded }) { [weak self, weak window] isOnboarded in
      guard let self, let window else { return }
      self.resize(window, forHub: isOnboarded)
    }
    return window
  }

  /// Gives the window the size of what it shows: small for setup, large (and remembered) for the hub.
  private func resize(_ window: NSWindow, forHub isHub: Bool) {
    guard isHub else {
      // Setup has its own size, which must not be remembered as the hub's.
      window.setFrameAutosaveName("")
      window.minSize = Self.setupSize
      window.setContentSize(Self.setupSize)
      window.center()
      return
    }
    window.minSize = Self.minimumSize
    if !(remembersFrame && window.setFrameUsingName(Self.frameName)) {
      let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: Self.defaultSize)).size
      let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(origin: .zero, size: size)
      let fitted = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
      let frame = CGRect(
        x: (area.midX - fitted.width / 2).rounded(),
        y: (area.midY - fitted.height / 2).rounded(),
        width: fitted.width,
        height: fitted.height
      )
      window.setFrame(frame, display: true, animate: window.isVisible)
    }
    if remembersFrame { window.setFrameAutosaveName(Self.frameName) }
  }

  // MARK: - NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    // Back to a menu bar app, once the window is really gone (and no update is on screen).
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isOpen else { return }
      DockIcon.hide(for: .hub)
    }
  }

  func windowDidEnterFullScreen(_ notification: Notification) {
    navigation.isFullScreen = true
  }

  func windowWillExitFullScreen(_ notification: Notification) {
    navigation.isFullScreen = false
  }
}
