import AppKit
import SwiftUI
import WisperDomain
import WisperEngine
import WisperMacUI
import WisperUI

/// The window of the floating pill: see-through, always on top, on every
/// Space and over full-screen apps. It never takes the keyboard and never
/// becomes the front app.
///
/// Where it is:
/// - Until it is moved, at the middle of the bottom edge of the screen the
///   pointer is on.
/// - It can be dragged. Let go, it settles against the nearest edge of the
///   screen it is on (bottom, top, left or right) and stays on that display.
///   The spot is remembered for each arrangement of displays (`PillSpots`);
///   a spot that no longer fits falls back to the bottom middle.
/// - A press that hardly moves is still a click. A press that moves further
///   is a drag, and the release that ends it clicks nothing.
///
/// Clicks pass straight through it, except on the pill itself. To make that
/// exact, the panel follows the pointer on its own instead of relying on the
/// system: it lets clicks in only while the pointer is over the pill.
///
/// It sits just under the Dock in the stacking order. A Dock that is always
/// showing is never covered (the pill is placed beside it); a Dock that hides
/// itself slides over the pill, so its icons can be seen and clicked.
@MainActor
final class PillPanel {
  private let panel: Panel
  private let pointer = PillPointer()
  private let model: AppModel
  private let controls: MacControls
  private var tracking: Task<Void, Never>?
  private var watches: [AnyObject] = []
  private var screenObserver: (any NSObjectProtocol)?
  private var mouseMonitor: Any?
  /// Where the pill is docked right now.
  private var home: Home?
  /// The press of the mouse button that is down on the pill, and the drag it may have become.
  private var press: Press?
  /// The end of a drag: the pill gliding to its edge.
  private var settling: Task<Void, Never>?

  /// A docked pill: its screen, its spot there and the window frame that goes with them.
  private struct Home: Equatable {
    var screen: PillScreen
    var spot: PillSpot
    var frame: CGRect
  }

  private struct Press {
    var start: CGPoint
    /// From the pointer to the middle of the pill, so the pill stays under the pointer where it was taken.
    var grip = CGPoint.zero
    var isDrag = false
    /// The screen the pill is over and the edge it would dock to, while dragging.
    var screen: PillScreen?
    var edge = PillEdge.bottom
  }

  /// How far around the pill the pointer already counts as "on it". The resting pill is tiny.
  private static let reach: CGFloat = 6
  /// How long the pill takes to glide to its edge: a little longer than the kit's spring.
  private static let settleTime: Duration = .milliseconds(450)
  /// How long after a drag a click still does nothing.
  private static let clickBlock: Duration = .milliseconds(250)

  init(model: AppModel, controls: MacControls) {
    self.model = model
    self.controls = controls
    panel = Panel(
      contentRect: CGRect(origin: .zero, size: PillPlacement.flatPanel),
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
    panel.setAccessibilityHelp("Drag the pill to move it to any edge of the screen.")

    let host = PillHost(
      rootView: PillView(pointer: pointer)
        .environment(model)
        .environment(controls)
    )
    host.onRightClick = { [weak self] event, view in self?.showMenu(for: event, in: view) }
    host.frame = CGRect(origin: .zero, size: PillPlacement.flatPanel)
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
  }

  func show() {
    follow()
    panel.orderFrontRegardless()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        // A display came, went or changed: whatever was going on with the pointer is over.
        self.endDrag(docking: false)
        self.follow()
      }
    }
    // Sees every press, move and release of the mouse button on the pill before the pill's
    // own buttons do. They still get each one: only a drag is taken out of their hands.
    mouseMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        if let self, event.window === self.panel { self.mouse(event.type) }
      }
      return event
    }
    // Starts looking at the pointer, and starts over at once when the pill comes or goes.
    watches.append(Watch({ [pointer] in pointer.hotFrame.isEmpty }) { [weak self] _ in self?.track() })
    // "Reset pill position" takes effect at once.
    watches.append(Watch({ [controls] in controls.pillSpots.memory }) { [weak self] _ in self?.follow() })
  }

  /// Looks at the pointer again and again: often while it is close to the pill, now and then
  /// while it is far, and only once a second while there is no pill to point at.
  private func track() {
    tracking?.cancel()
    tracking = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let near = self.follow()
        // While the pill is carried it keeps up with the pointer even if no mouse event arrives.
        let pause = self.press?.isDrag == true ? 8 : self.pointer.hotFrame.isEmpty ? 1000 : near ? 33 : 150
        try? await Task.sleep(for: .milliseconds(pause))
      }
    }
  }

  /// Puts the pill where it belongs and works out whether the pointer is on it.
  /// Returns whether the pointer is near the pill.
  @discardableResult
  private func follow() -> Bool {
    let mouse = NSEvent.mouseLocation
    if press != nil {
      // The mouse events normally do this. Looking here as well means a drag still works, and
      // still ends, when a move or the release never reaches the window.
      if NSEvent.pressedMouseButtons & 1 != 0 {
        drag(to: mouse)
      } else if press?.isDrag == true {
        endDrag(docking: true)
      } else {
        press = nil
      }
      if press?.isDrag == true { return true }
    }
    guard settling == nil else { return true }
    // Stay put while the mouse button is down on the pill, or the click would miss.
    if NSEvent.pressedMouseButtons == 0 || !pointer.isHovered, let wanted = wantedHome(), wanted != home {
      dock(at: wanted)
    }
    let hot = pointer.hotFrame
    guard !hot.isEmpty else {
      setHovered(false)
      return false
    }
    let onScreen = screenRect(of: hot)
    setHovered(onScreen.insetBy(dx: -Self.reach, dy: -Self.reach).contains(mouse))
    return onScreen.insetBy(dx: -160, dy: -160).contains(mouse)
  }

  /// The view measures from its top left; the screen from its bottom left.
  private func screenRect(of rect: CGRect) -> CGRect {
    CGRect(
      x: panel.frame.minX + rect.minX,
      y: panel.frame.maxY - rect.maxY,
      width: rect.width,
      height: rect.height
    )
  }

  private func setHovered(_ hovered: Bool) {
    if pointer.isHovered != hovered { pointer.isHovered = hovered }
    if panel.ignoresMouseEvents == hovered { panel.ignoresMouseEvents = !hovered }
  }

  // MARK: - Where it belongs

  /// The remembered spot for the displays that are there, or else the bottom middle of the
  /// screen the pointer is on.
  private func wantedHome() -> Home? {
    let screens = NSScreen.screens
    let described = screens.map(Self.describe)
    guard !described.isEmpty else { return nil }
    let screen: PillScreen
    let spot: PillSpot
    if let saved = controls.pillSpots.memory.placement(among: described) {
      screen = described[saved.screen]
      spot = saved.spot
    } else {
      let mouse = NSEvent.mouseLocation
      // Between two displays the pointer is on neither: the pill stays where it is.
      let index =
        described.firstIndex { $0.frame.contains(mouse) }
        ?? home.flatMap { now in described.firstIndex { $0.frame == now.screen.frame } }
      screen = described[index ?? 0]
      spot = .home
    }
    return Home(screen: screen, spot: spot, frame: PillPlacement.panelFrame(for: spot, on: screen))
  }

  /// Moves the window to a docked spot and tells the pill which way it faces there.
  private func dock(at wanted: Home) {
    home = wanted
    let foot = PillPlacement.foot(of: wanted.spot, on: wanted.screen)
    retarget(frame: wanted.frame, edge: wanted.spot.edge, foot: foot, isFloating: false)
  }

  /// Changes the window's frame and what the pill is told in one go, so the pill is never
  /// drawn once in the old place of a new window.
  private func retarget(frame: CGRect, edge: PillEdge, foot: CGPoint, isFloating: Bool) {
    var quiet = Transaction()
    quiet.disablesAnimations = true
    withTransaction(quiet) {
      pointer.edge = edge
      pointer.foot = PillPlacement.viewPoint(foot, in: frame)
      pointer.isFloating = isFloating
    }
    guard panel.frame != frame else { return }
    panel.disableScreenUpdatesUntilFlush()
    panel.setFrame(frame, display: false)
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
  }

  private static func describe(_ screen: NSScreen) -> PillScreen {
    PillScreen(frame: screen.frame, visibleFrame: screen.visibleFrame, topInset: screen.safeAreaInsets.top)
  }

  // MARK: - Dragging

  /// One press, move or release of the mouse button on the pill.
  private func mouse(_ type: NSEvent.EventType) {
    switch type {
    case .leftMouseDown:
      settleNow()
      press = pointer.canMove ? Press(start: NSEvent.mouseLocation) : nil
      // Look often from now on, in case the moves that follow are not shown to us.
      if press != nil { track() }
    case .leftMouseDragged:
      drag(to: NSEvent.mouseLocation)
    case .leftMouseUp:
      // The pill's buttons get this release next, and do nothing with it: clicks are blocked.
      if press?.isDrag == true { endDrag(docking: true) }
      press = nil
    default:
      break
    }
  }

  private func drag(to mouse: CGPoint) {
    guard var press else { return }
    if !press.isDrag {
      guard PillPlacement.isDrag(from: press.start, to: mouse, isRecording: pointer.isRecording) else {
        return
      }
      press.isDrag = true
      press.edge = pointer.edge
      let pill = screenRect(of: pointer.hotFrame)
      press.grip = CGPoint(x: pill.midX - press.start.x, y: pill.midY - press.start.y)
      pointer.blocksClicks = true
    }
    let middle = CGPoint(x: mouse.x + press.grip.x, y: mouse.y + press.grip.y)
    let screens = NSScreen.screens.map(Self.describe)
    guard let index = PillPlacement.screen(for: mouse, among: screens) else { return }
    let screen = screens[index]
    // On a new screen the edge starts afresh: the nearest one there.
    let carried = press.screen?.frame == screen.frame ? press.edge : nil
    press.edge = PillPlacement.spot(droppedAt: middle, on: screen, from: carried).edge
    press.screen = screen
    self.press = press
    // While it is carried, the window covers the screen the pill is over and the pill moves
    // inside it. Nothing of the window can be seen or clicked but the pill.
    if pointer.isFloating, panel.frame == screen.frame {
      // The pill turns with the kit's spring when the nearest edge changes.
      if pointer.edge != press.edge { pointer.edge = press.edge }
      pointer.foot = PillPlacement.viewPoint(middle, in: screen.frame)
    } else {
      retarget(frame: screen.frame, edge: press.edge, foot: middle, isFloating: true)
    }
  }

  /// Ends a drag. With `docking`, the pill glides to the nearest edge and that spot is
  /// remembered; without, it goes back to where it was.
  private func endDrag(docking: Bool) {
    guard let press, press.isDrag else {
      self.press = nil
      return
    }
    self.press = nil
    let screens = NSScreen.screens.map(Self.describe)
    guard docking, let screen = press.screen, let index = screens.firstIndex(of: screen),
      let foot = pointer.foot
    else {
      finishSettling()
      return
    }
    // The pill's middle, back in screen terms.
    let middle = CGPoint(x: screen.frame.minX + foot.x, y: screen.frame.maxY - foot.y)
    let spot = PillPlacement.spot(droppedAt: middle, on: screen, from: press.edge)
    controls.pillSpots.remember(spot, onScreen: index, among: screens)
    let wanted = Home(screen: screen, spot: spot, frame: PillPlacement.panelFrame(for: spot, on: screen))
    home = wanted
    // Let go, it is no longer under the pointer in any way that counts.
    setHovered(false)
    // Still in the screen-sized window: the pill springs from the pointer to its edge.
    withAnimation(Wisper.Motion.spring) {
      pointer.edge = spot.edge
      pointer.foot = PillPlacement.viewPoint(PillPlacement.foot(of: spot, on: screen), in: screen.frame)
      pointer.isFloating = false
    }
    settling = Task { [weak self] in
      try? await Task.sleep(for: Wisper.Motion.reduceMotion ? .milliseconds(160) : Self.settleTime)
      guard !Task.isCancelled else { return }
      self?.finishSettling()
    }
  }

  /// Cuts a glide short, when the pill is pressed again while it is still on its way.
  private func settleNow() {
    guard settling != nil else { return }
    settling?.cancel()
    finishSettling()
  }

  /// Back to the small window at the pill's spot, and clicks count again a moment later.
  private func finishSettling() {
    settling = nil
    if let wanted = home ?? wantedHome() { dock(at: wanted) }
    Task { [weak self] in
      try? await Task.sleep(for: Self.clickBlock)
      guard let self, self.press?.isDrag != true else { return }
      self.pointer.blocksClicks = false
    }
    follow()
  }

  // MARK: - The menu

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
