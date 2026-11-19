import AppKit
import Observation
import WisperDomain

/// Decides when the keys a person presses add up to a shortcut. Pure, so the
/// rules can be tested without a keyboard.
///
/// - A key press finishes at once with that key and the modifiers held.
/// - Modifiers alone finish when the first of them is released, with all the
///   modifiers that were held together.
/// - Escape on its own cancels.
struct ShortcutCapture: Sendable {
  enum Step: Sendable, Equatable {
    /// Not finished. `held` is what is down right now, to show while recording.
    case waiting(held: KeyCombo)
    case finished(KeyCombo)
    case cancelled
  }

  private var modifiers: Set<KeyCombo.Modifier> = []
  private var most: Set<KeyCombo.Modifier> = []

  mutating func handle(_ input: KeyInput) -> Step {
    switch input {
    case .modifiers(let new):
      let released = !modifiers.subtracting(new).isEmpty
      modifiers = new
      if released, !most.isEmpty { return .finished(KeyCombo(modifiers: most)) }
      most = new
      return .waiting(held: KeyCombo(modifiers: new))
    case .keyDown(let code, let eventModifiers, let isRepeat):
      guard !isRepeat else { return .waiting(held: KeyCombo(modifiers: modifiers)) }
      // fn on a key event cannot be trusted: arrow and function keys set it themselves.
      let held = eventModifiers.subtracting([.function]).union(modifiers.intersection([.function]))
      if code == KeyCombo.KeyCode.escape, held.isEmpty { return .cancelled }
      return .finished(KeyCombo(keyCode: code, modifiers: held))
    case .keyUp:
      return .waiting(held: KeyCombo(modifiers: modifiers))
    }
  }
}

/// Records a new shortcut for the settings screen.
///
/// ```swift
/// if let combo = await recorder.record() { ... }   // nil: cancelled
/// ```
///
/// Works while one of the app's own windows has the keyboard, and needs no
/// permission. While recording, key presses do not reach the window. The
/// result is whatever was pressed; check it with `KeyCombo.problem(for:in:)`
/// before saving it.
@MainActor
@Observable
public final class ShortcutRecorder {
  /// True between the call to `record()` and its return.
  public private(set) var isRecording = false
  /// The keys held right now while recording, to show as key caps.
  public private(set) var held = KeyCombo()

  @ObservationIgnored private weak var monitor: ShortcutMonitor?
  @ObservationIgnored private var capture = ShortcutCapture()
  @ObservationIgnored private var tracker = ModifierTracker()
  @ObservationIgnored private var eventTap: Any?
  @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?
  @ObservationIgnored private var waiter: CheckedContinuation<KeyCombo?, Never>?

  /// `monitor` is suspended for as long as a recording runs, so the keys
  /// being recorded do not also set off a dictation.
  public init(suspending monitor: ShortcutMonitor? = nil) {
    self.monitor = monitor
  }

  /// Waits for the next shortcut the user presses: a key with modifiers, or
  /// modifiers alone (taken when they are released). Returns nil when the
  /// user presses Escape, the app loses focus, or `cancel()` is called.
  /// A second call while one is running cancels the first.
  public func record() async -> KeyCombo? {
    finish(nil)
    isRecording = true
    held = KeyCombo()
    capture = ShortcutCapture()
    tracker = ModifierTracker()
    monitor?.isSuspended = true
    eventTap = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
      [weak self] event in
      guard let self, self.isRecording else { return event }
      self.handle(event)
      return nil
    }
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.finish(nil) }
    }
    return await withCheckedContinuation { waiter = $0 }
  }

  /// Stops a recording in progress; `record()` returns nil.
  public func cancel() {
    finish(nil)
  }

  private func handle(_ event: NSEvent) {
    let modifiers = Set<KeyCombo.Modifier>(event.modifierFlags)
    let input: KeyInput
    switch event.type {
    case .flagsChanged: input = .modifiers(tracker.modifierChanged(flags: modifiers, keyCode: event.keyCode))
    case .keyDown: input = .keyDown(event.keyCode, modifiers: modifiers, isRepeat: event.isARepeat)
    default: input = .keyUp(event.keyCode)
    }
    switch capture.handle(input) {
    case .waiting(let held): self.held = held
    case .finished(let combo): finish(combo)
    case .cancelled: finish(nil)
    }
  }

  private func finish(_ combo: KeyCombo?) {
    guard isRecording else { return }
    isRecording = false
    held = KeyCombo()
    if let eventTap { NSEvent.removeMonitor(eventTap) }
    eventTap = nil
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    resignObserver = nil
    monitor?.isSuspended = false
    waiter?.resume(returning: combo)
    waiter = nil
  }
}

extension Set<KeyCombo.Modifier> {
  /// The modifiers named by the flags of an AppKit event.
  init(_ flags: NSEvent.ModifierFlags) {
    self.init()
    if flags.contains(.function) { insert(.function) }
    if flags.contains(.control) { insert(.control) }
    if flags.contains(.option) { insert(.option) }
    if flags.contains(.shift) { insert(.shift) }
    if flags.contains(.command) { insert(.command) }
  }
}
