import ApplicationServices
import CoreGraphics
import Foundation
import SpacesDomain

/// Watches every key press on the Mac and feeds it to a `ShortcutMatcher`.
///
/// The tap is an *active* one: it can stop a key press from reaching the app
/// in front. That is needed so that fn+Space does not also type a space and
/// ⌃⌘V does not also reach the app. Modifier keys and every key that is not
/// part of a shortcut pass through untouched. The one other thing it can hold
/// back is the key press macOS makes up for a lone tap of fn (Globe), which
/// is what opens the emoji picker; fn itself, fn+arrow and fn+F-keys are
/// never touched. An active tap needs the
/// Accessibility permission and nothing else (a listen-only tap would need
/// Input Monitoring instead, and could not hold a key back).
///
/// The tap runs on its own thread. Every key press on the Mac waits for the
/// tap to answer, so it must never wait for the app's main thread.
final class KeyboardTap: @unchecked Sendable {
  /// Marks key presses this app makes itself (paste, copy) so the tap ignores them.
  static let ownEventTag: Int64 = 0x4F57_6B65_79

  private static let tickInterval: CFTimeInterval = 0.25

  /// Receives events in the order they happened. Called on the tap's thread
  /// or the caller's, with the tap's lock held: it must only pass the events
  /// on (to the main queue) and never call back into the tap.
  private let sink: @Sendable ([ShortcutEvent]) -> Void

  private let lock = NSLock()
  // Everything below is guarded by `lock`.
  private var matcher = ShortcutMatcher()
  private var tracker = ModifierTracker()
  private var suspended = false
  private var session: Session?
  private var ticks = 0
  /// Held modifiers and keys the system has been seen to report as down.
  /// Only those are believed when the system later says they are up.
  private var confirmedModifiers: Set<KeyCombo.Modifier> = []
  private var confirmedKeys: Set<UInt16> = []

  /// The live tap and the run loop it is served on.
  private final class Session: @unchecked Sendable {
    let port: CFMachPort
    let runLoop: CFRunLoop
    private let lock = NSLock()
    private var stopping = false

    init(port: CFMachPort, runLoop: CFRunLoop) {
      self.port = port
      self.runLoop = runLoop
    }

    var isStopping: Bool { lock.withLock { stopping } }

    func requestStop() {
      lock.withLock { stopping = true }
      CGEvent.tapEnable(tap: port, enable: false)
      CFRunLoopStop(runLoop)
    }
  }

  init(sink: @escaping @Sendable ([ShortcutEvent]) -> Void) {
    self.sink = sink
  }

  var isRunning: Bool { lock.withLock { session != nil } }

  /// Changes the shortcuts. Whatever was held is reported as abandoned.
  func setShortcuts(_ shortcuts: [ShortcutAction: KeyCombo]) {
    lock.withLock {
      guard matcher.shortcuts != shortcuts else { return }
      matcher.shortcuts = shortcuts
      abandonAll()
    }
  }

  func setCancelsOnEscape(_ value: Bool) {
    lock.withLock { matcher.cancelsOnEscape = value }
  }

  func setHoldsBackGlobeKey(_ value: Bool) {
    lock.withLock { matcher.holdsBackGlobeKey = value }
  }

  /// While suspended nothing is reported and no key is held back.
  func setSuspended(_ value: Bool) {
    lock.withLock {
      guard suspended != value else { return }
      suspended = value
      abandonAll()
    }
  }

  /// Starts watching. False when the Accessibility permission is missing.
  func start() -> Bool {
    if isRunning { return true }
    // Without the permission the tap cannot be made, and trying could show a
    // system prompt. Asking is the job of `MacPermissions`.
    guard AXIsProcessTrusted() else { return false }
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread { [self] in run(ready: ready) }
    thread.name = "Spaces shortcuts"
    thread.qualityOfService = .userInteractive
    thread.start()
    ready.wait()
    return isRunning
  }

  func stop() {
    let ended = lock.withLock {
      let ended = session
      session = nil
      abandonAll()
      return ended
    }
    ended?.requestStop()
  }

  // MARK: - The tap's thread

  private func run(ready: DispatchSemaphore) {
    let mask =
      CGEventMask(1) << CGEventType.keyDown.rawValue
      | CGEventMask(1) << CGEventType.keyUp.rawValue
      | CGEventMask(1) << CGEventType.flagsChanged.rawValue
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: keyboardTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      ),
      let runLoop = CFRunLoopGetCurrent()
    else {
      ready.signal()
      return
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(runLoop, source, .commonModes)
    let timer = CFRunLoopTimerCreateWithHandler(
      kCFAllocatorDefault,
      CFAbsoluteTimeGetCurrent() + Self.tickInterval,
      Self.tickInterval,
      0,
      0
    ) { [weak self] _ in self?.tick() }
    CFRunLoopAddTimer(runLoop, timer, .commonModes)

    let session = Session(port: port, runLoop: runLoop)
    lock.withLock {
      self.session = session
      // Modifiers held right now must not look like a fresh press.
      let held = Self.physicalModifiers()
      tracker = ModifierTracker(isFunctionDown: held.contains(.function))
      _ = matcher.reset(modifiers: held)
      confirmedModifiers = []
      confirmedKeys = []
    }
    CGEvent.tapEnable(tap: port, enable: true)
    ready.signal()

    // `self` stays alive for as long as this loop runs, so the pointer the
    // tap callback holds is always good.
    while !session.isStopping {
      CFRunLoopRunInMode(.defaultMode, 0.5, false)
    }

    CFRunLoopTimerInvalidate(timer)
    CFRunLoopRemoveSource(runLoop, source, .commonModes)
    CFMachPortInvalidate(port)
  }

  /// Called for every key event. Returns true to keep the event from the app in front.
  fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      // The system switches a tap off when it is slow to answer. Switch it
      // back on and catch up on anything missed meanwhile.
      if let port = lock.withLock({ session?.port }) { CGEvent.tapEnable(tap: port, enable: true) }
      resync()
      return false
    case .keyDown, .keyUp, .flagsChanged:
      break
    default:
      return false
    }
    guard event.getIntegerValueField(.eventSourceUserData) != Self.ownEventTag else { return false }

    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let flags = Set<KeyCombo.Modifier>(event.flags)
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let now = ProcessInfo.processInfo.systemUptime

    return lock.withLock {
      let input: KeyInput
      switch type {
      case .flagsChanged: input = .modifiers(tracker.modifierChanged(flags: flags, keyCode: keyCode))
      case .keyDown: input = .keyDown(keyCode, modifiers: flags, isRepeat: isRepeat)
      default: input = .keyUp(keyCode)
      }
      // While suspended the modifiers are still followed, so that nothing
      // looks like a fresh press when watching resumes.
      guard !suspended else {
        if case .modifiers(let held) = input { _ = matcher.reset(modifiers: held) }
        return false
      }
      let output = matcher.handle(input, at: now)
      confirmedModifiers.formIntersection(matcher.modifiers)
      confirmedKeys.formIntersection(matcher.trackedKeys)
      if !output.events.isEmpty { sink(output.events) }
      return output.swallow
    }
  }

  private func tick() {
    let (current, count) = lock.withLock {
      ticks += 1
      return (session, ticks)
    }
    guard let current, !current.isStopping else { return }
    // If the permission is taken away while an active tap is running, key
    // presses can get stuck. Let go of the tap as soon as that is noticed.
    if count % 4 == 0, !AXIsProcessTrusted() {
      stop()
      return
    }
    if !CGEvent.tapIsEnabled(tap: current.port) { CGEvent.tapEnable(tap: current.port, enable: true) }
    resync()
  }

  /// Compares what the matcher believes is held with what the system says.
  /// A release can be missed (the tap was switched off for a moment, or a
  /// password field was in front), and a dictation must never be left running
  /// because of it.
  private func resync() {
    let (believed, tracked) = lock.withLock { (matcher.modifiers, matcher.trackedKeys) }
    guard !believed.isEmpty || !tracked.isEmpty else { return }

    let down = Self.physicalModifiers()
    let keysDown = tracked.filter { CGEventSource.keyState(.hidSystemState, key: $0) }
    let now = ProcessInfo.processInfo.systemUptime

    lock.withLock {
      // "Up" is only believed for something the system was seen to report as
      // down during this hold. If the system cannot see a key at all, the
      // matcher's own view stands.
      confirmedModifiers.formUnion(down.intersection(matcher.modifiers))
      confirmedKeys.formUnion(keysDown.intersection(matcher.trackedKeys))
      let lifted = matcher.modifiers.subtracting(down).intersection(confirmedModifiers)
      let releasedKeys = matcher.trackedKeys.subtracting(keysDown).intersection(confirmedKeys)
      guard !lifted.isEmpty || !releasedKeys.isEmpty else { return }
      let held = matcher.modifiers.subtracting(lifted)
      if lifted.contains(.function) { tracker.functionReleased() }
      confirmedModifiers.subtract(lifted)
      confirmedKeys.subtract(releasedKeys)
      guard !suspended else {
        _ = matcher.reset(modifiers: held)
        return
      }
      let events = matcher.resync(modifiers: held, releasedKeys: releasedKeys, at: now)
      if !events.isEmpty { sink(events) }
    }
  }

  /// The keys that carry each modifier (left and right).
  private static let modifierKeys: [(KeyCombo.Modifier, [CGKeyCode])] = [
    (.function, [63, 179]), (.control, [59, 62]), (.option, [58, 61]), (.shift, [56, 60]),
    (.command, [55, 54]),
  ]

  /// The modifiers that are down on the keyboard itself. Asked two ways (the
  /// keyboard's flags and each key), and a modifier counts as down if either
  /// says so: wrongly ending a dictation is worse than checking again later.
  /// Key presses made by programs do not show up here, only real keys.
  private static func physicalModifiers() -> Set<KeyCombo.Modifier> {
    var down = Set<KeyCombo.Modifier>(CGEventSource.flagsState(.hidSystemState))
    for (modifier, keys) in modifierKeys
    where keys.contains(where: { CGEventSource.keyState(.hidSystemState, key: $0) }) {
      down.insert(modifier)
    }
    return down
  }

  /// Reports whatever is held as abandoned. Call with `lock` held.
  private func abandonAll() {
    let events = matcher.reset(modifiers: matcher.modifiers)
    confirmedKeys = []
    if !events.isEmpty { sink(events) }
  }
}

private func keyboardTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<KeyboardTap>.fromOpaque(userInfo).takeUnretainedValue()
  return tap.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

extension Set<KeyCombo.Modifier> {
  /// The modifiers named by the flags of a keyboard event.
  init(_ flags: CGEventFlags) {
    self.init()
    if flags.contains(.maskSecondaryFn) { insert(.function) }
    if flags.contains(.maskControl) { insert(.control) }
    if flags.contains(.maskAlternate) { insert(.option) }
    if flags.contains(.maskShift) { insert(.shift) }
    if flags.contains(.maskCommand) { insert(.command) }
  }
}
