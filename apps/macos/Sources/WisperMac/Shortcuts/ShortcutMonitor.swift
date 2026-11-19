import Foundation
import WisperDomain

/// Watches the keyboard everywhere on the Mac and reports when one of the
/// user's shortcuts is pressed and released.
///
/// ```swift
/// let monitor = ShortcutMonitor()
/// monitor.onEvent = { event in ... }
/// monitor.setShortcuts(settings.shortcuts)
/// if !monitor.start() { /* ask for Accessibility, then call start() again */ }
/// ```
///
/// What a caller can rely on:
/// - Events arrive on the main actor, in the order they happened.
/// - Every `down` is followed by exactly one `up`, `abandoned` or `cancel`,
///   even when keys are released in another order, the shortcuts change,
///   the monitor is suspended or stopped, or a key release is missed.
/// - Push to talk starts the moment its keys are down. When the user goes on
///   to a longer shortcut (fn, then Space or ⌃), the first is reported as
///   `abandoned(_, replacedBy:)` right before the `down` of the longer one.
/// - A key press that belongs to a shortcut (the Space of fn+Space, the V of
///   ⌃⌘V) and an Escape that cancels do not reach the app in front.
///   Everything else is passed on untouched.
@MainActor
public final class ShortcutMonitor {
  public typealias Event = ShortcutEvent

  /// Called for every shortcut event.
  public var onEvent: (@MainActor (ShortcutEvent) -> Void)?

  /// While true nothing is reported and no key is held back. Set it while
  /// the settings screen records a new shortcut (`ShortcutRecorder` does
  /// this on its own when given the monitor).
  public var isSuspended = false {
    didSet { tap.setSuspended(isSuspended) }
  }

  /// Turn on while there is a recording to cancel that is not a held key (a
  /// hands-free recording). While on, a press of Escape is reported as
  /// `.cancel` and does not reach the app in front. Turn it off again as soon
  /// as the recording is over, or Escape stops working elsewhere.
  public var cancelsOnEscape = false {
    didSet { tap.setCancelsOnEscape(cancelsOnEscape) }
  }

  private let tap: KeyboardTap
  private let inbox: Inbox

  /// Carries events from the tap's thread to the main actor.
  private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var monitor: ShortcutMonitor?

    func attach(_ monitor: ShortcutMonitor) {
      lock.withLock { self.monitor = monitor }
    }

    func post(_ events: [ShortcutEvent]) {
      DispatchQueue.main.async { [self] in
        MainActor.assumeIsolated {
          guard let monitor = lock.withLock({ self.monitor }) else { return }
          for event in events { monitor.onEvent?(event) }
        }
      }
    }
  }

  public init() {
    let inbox = Inbox()
    self.inbox = inbox
    tap = KeyboardTap { events in inbox.post(events) }
    inbox.attach(self)
  }

  deinit {
    tap.stop()
  }

  /// The shortcuts to watch for. Safe to call at any time; anything held at
  /// that moment is reported as abandoned.
  public func setShortcuts(_ shortcuts: [ShortcutAction: KeyCombo]) {
    tap.setShortcuts(shortcuts.filter { !$0.value.isEmpty })
  }

  /// Starts watching. Returns false when the Accessibility permission has not
  /// been granted; ask for it with `MacPermissions` and call `start()` again.
  /// Does nothing when already running. Never shows a system prompt.
  @discardableResult
  public func start() -> Bool {
    tap.start()
  }

  /// Stops watching. Anything held is reported as abandoned.
  public func stop() {
    tap.stop()
  }

  /// False before `start()`, after `stop()`, and after the Accessibility
  /// permission was taken away while running (the monitor then stops itself).
  public var isRunning: Bool { tap.isRunning }
}
