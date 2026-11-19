import AppKit
import SwiftUI
import WisperDomain
import WisperEngine
import WisperMacUI

/// The window of the floating pill: see-through, always on top, on every
/// Space and over full-screen apps, at the bottom centre of the screen the
/// pointer is on. It never takes the keyboard and never becomes the front app.
///
/// Clicks pass straight through it, except on the pill itself. To make that
/// exact, the panel follows the pointer on its own instead of relying on the
/// system: it lets clicks in only while the pointer is over the pill.
///
/// It sits just under the Dock in the stacking order. A Dock that is always
/// showing is never covered (the pill is placed above it); a Dock that hides
/// itself slides up over the pill, so its icons can be seen and clicked.
@MainActor
final class PillPanel {
  private let panel: Panel
  private let pointer = PillPointer()
  private let model: AppModel
  private let controls: MacControls
  private var tracking: Task<Void, Never>?
  private var pillWatch: Watch<Bool>?
  private var screenObserver: (any NSObjectProtocol)?
  private var screenID: CGDirectDisplayID?

  /// Room for the widest notice and for the hint above the pill.
  private static let size = CGSize(width: 480, height: 150)
  /// How far around the pill the pointer already counts as "on it". The resting pill is tiny.
  private static let reach: CGFloat = 6

  init(model: AppModel, controls: MacControls) {
    self.model = model
    self.controls = controls
    panel = Panel(
      contentRect: CGRect(origin: .zero, size: Self.size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.ignoresMouseEvents = true
    panel.appearance = NSAppearance(named: .aqua)
    panel.setAccessibilityLabel("Open Wisper pill")

    let host = PillHost(
      rootView: PillView(pointer: pointer)
        .environment(model)
        .environment(controls)
    )
    host.onRightClick = { [weak self] event, view in self?.showMenu(for: event, in: view) }
    host.frame = CGRect(origin: .zero, size: Self.size)
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
  }

  func show() {
    place(on: Self.screenUnderPointer() ?? NSScreen.main)
    panel.orderFrontRegardless()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.screenID = nil
        self.follow()
      }
    }
    // Starts looking at the pointer, and starts over at once when the pill comes or goes.
    pillWatch = Watch({ [pointer] in pointer.hotFrame.isEmpty }) { [weak self] _ in self?.track() }
  }

  /// Looks at the pointer again and again: often while it is close to the pill, now and then
  /// while it is far, and only once a second while there is no pill to point at.
  private func track() {
    tracking?.cancel()
    tracking = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let near = self.follow()
        let pause = self.pointer.hotFrame.isEmpty ? 1000 : near ? 33 : 150
        try? await Task.sleep(for: .milliseconds(pause))
      }
    }
  }

  /// Moves to the pointer's screen and works out whether the pointer is on the pill.
  /// Returns whether the pointer is near the pill.
  @discardableResult
  private func follow() -> Bool {
    let mouse = NSEvent.mouseLocation
    let screen = Self.screenUnderPointer() ?? panel.screen ?? NSScreen.main
    if let screen, Self.id(of: screen) != screenID || panel.frame.origin != Self.origin(on: screen) {
      // Stay put while the mouse button is down on the pill, or the click would miss.
      if NSEvent.pressedMouseButtons == 0 || !pointer.isHovered { place(on: screen) }
    }
    let hot = pointer.hotFrame
    guard !hot.isEmpty else {
      setHovered(false)
      return false
    }
    // The view measures from its top left; the screen from its bottom left.
    let onScreen = CGRect(
      x: panel.frame.minX + hot.minX,
      y: panel.frame.maxY - hot.maxY,
      width: hot.width,
      height: hot.height
    )
    setHovered(onScreen.insetBy(dx: -Self.reach, dy: -Self.reach).contains(mouse))
    return onScreen.insetBy(dx: -160, dy: -160).contains(mouse)
  }

  private func setHovered(_ hovered: Bool) {
    if pointer.isHovered != hovered { pointer.isHovered = hovered }
    if panel.ignoresMouseEvents == hovered { panel.ignoresMouseEvents = !hovered }
  }

  private func place(on screen: NSScreen?) {
    guard let screen else { return }
    screenID = Self.id(of: screen)
    panel.setFrame(CGRect(origin: Self.origin(on: screen), size: Self.size), display: true)
  }

  /// Bottom centre, just above the Dock when the Dock is showing.
  private static func origin(on screen: NSScreen) -> CGPoint {
    CGPoint(
      x: (screen.frame.midX - size.width / 2).rounded(),
      y: max(screen.visibleFrame.minY, screen.frame.minY) + 2
    )
  }

  private static func screenUnderPointer() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouse) }
  }

  private static func id(of screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  private func showMenu(for event: NSEvent, in view: NSView) {
    Task { [weak self, model, controls] in
      let microphones = await model.capture.microphones()
      guard self != nil else { return }
      let entries = MenuBarContent.pillEntries(for: model, controls: controls, microphones: microphones)
      let menu = Menus.menu(entries) { command in
        MenuBarContent.perform(command, model: model, controls: controls)
      }
      NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
  }

  /// A panel that can be clicked without taking the keyboard away from the app in front.
  private final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }
}

/// Hosts the pill. Takes the first click (the panel is never the active window) and reports right clicks.
private final class PillHost<Content: View>: NSHostingView<Content> {
  var onRightClick: (@MainActor (NSEvent, NSView) -> Void)?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func rightMouseDown(with event: NSEvent) {
    onRightClick?(event, self)
  }
}
