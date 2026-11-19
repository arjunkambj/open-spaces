import Foundation
import Observation
import WisperDomain
import WisperEngine
import WisperMac

/// Everything on the Mac that can start, stop or cancel a dictation or a
/// meeting: the global shortcuts, the floating pill, the menu bar and links.
///
/// ```swift
/// let controls = MacControls(model: model, monitor: ShortcutMonitor(), sounds: SoundPlayer())
/// controls.open = { destination in ... }   // show the hub, settings or a meeting
/// controls.start()                         // begin listening for the shortcuts
/// ```
///
/// What a caller can rely on:
/// - Shortcut events may be fed in any order the monitor can produce; a press
///   that turns out to be something else (fn + arrow) leaves no trace.
/// - Push to talk records from the instant the key goes down, but the
///   recording look and the start sound wait a moment (`showsRecording`), so a
///   key that was only passing through never flashes or beeps.
/// - Nothing is recorded without an OpenAI key (unless a custom server is
///   set): a notice says what to do instead.
/// - Every problem a person should see lands in `notice` and clears itself
///   after a few seconds.
/// - Shortcuts follow the settings on their own, also when another program
///   changes them, and come back by themselves once Accessibility is granted.
@MainActor
@Observable
public final class MacControls {
  /// A short message for the floating pill.
  public struct Notice: Equatable, Sendable {
    /// What a click on the notice does.
    public enum Fix: Equatable, Sendable {
      /// Open Settings (the key is missing or wrong).
      case settings
      /// Ask for a permission, or open System Settings where it is switched on.
      case permission(Permission)
      /// Show the main window.
      case hub
    }

    public var message: String
    public var fix: Fix?

    public init(message: String, fix: Fix? = nil) {
      self.message = message
      self.fix = fix
    }
  }

  /// A place in the app that a control can ask to be shown.
  public enum Destination: Equatable, Sendable {
    case hub
    case settings
    case meeting(Meeting.ID)
  }

  /// The message to show right now, if any.
  public internal(set) var notice: Notice?
  /// True while a recording should look like one. Lags the engine by a moment
  /// for push to talk; see the type's description.
  public internal(set) var showsRecording = false
  /// True from the moment a recording was asked to end until the engine has taken over.
  public private(set) var isWrappingUp = false
  /// False when the shortcuts cannot be heard because Accessibility access is missing.
  public internal(set) var needsAccessibility = false
  /// The pill stays out of sight until this moment (it still shows while recording).
  public private(set) var pillHiddenUntil: Date?

  /// Shows a part of the app. Set by the app; does nothing until then.
  @ObservationIgnored public var open: @MainActor (Destination) -> Void = { _ in }
  /// The shortcut monitor, for the shortcut recorder to pause. `nil` when shortcuts are off (the demo).
  @ObservationIgnored public let monitor: ShortcutMonitor?

  @ObservationIgnored private let model: AppModel
  @ObservationIgnored private let sounds: SoundPlayer?
  @ObservationIgnored private let revealDelay: Duration
  @ObservationIgnored private let noticeTime: Duration

  /// The hold action (push to talk, command mode) whose key is down and whose release ends the recording.
  @ObservationIgnored private var held: ShortcutAction?
  /// Push to talk went down while a recording was running: letting it go ends that recording.
  @ObservationIgnored private var endsOnRelease = false
  /// The recording was already showing when its shortcut grew into a longer one: keep showing, no second sound.
  @ObservationIgnored private var carriesOver = false
  /// Goes up with every recording, so late tasks know they belong to an old one.
  @ObservationIgnored private var run = 0
  @ObservationIgnored private var lastPhase = DictationEngine.Phase.idle
  @ObservationIgnored private var reveal: Task<Void, Never>?
  @ObservationIgnored private var noticeTimer: Task<Void, Never>?
  @ObservationIgnored private var pillTimer: Task<Void, Never>?
  @ObservationIgnored private var upkeep: Task<Void, Never>?
  @ObservationIgnored private var watches: [AnyObject] = []

  /// - monitor: the global shortcuts, or `nil` to run without them.
  /// - sounds: plays the start, stop and error sounds, or `nil` for silence.
  /// - revealDelay: how long push to talk waits before it looks and sounds like a recording.
  /// - noticeTime: how long a notice stays up.
  public init(
    model: AppModel,
    monitor: ShortcutMonitor? = nil,
    sounds: SoundPlayer? = nil,
    revealDelay: Duration = .milliseconds(150),
    noticeTime: Duration = .seconds(5)
  ) {
    self.model = model
    self.monitor = monitor
    self.sounds = sounds
    self.revealDelay = revealDelay
    self.noticeTime = noticeTime
    watches.append(
      Watch({ [model] in model.dictation.phase }) { [weak self] phase in self?.phaseChanged(to: phase) }
    )
  }

  // MARK: - Shortcuts

  /// Starts listening for the global shortcuts and keeps them in step with the
  /// settings. Safe to call again. Without Accessibility access it keeps
  /// trying quietly and sets `needsAccessibility` meanwhile.
  public func start() {
    guard let monitor, upkeep == nil else { return }
    monitor.onEvent = { [weak self] event in self?.handle(event) }
    watches.append(
      Watch({ [model] in model.settings.shortcuts }) { [weak monitor] shortcuts in
        monitor?.setShortcuts(shortcuts)
      }
    )
    needsAccessibility = !monitor.start()
    upkeep = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard let self, let monitor = self.monitor else { return }
        // Starting is a no-op while running, and never shows a system prompt.
        let missing = !monitor.start()
        if missing != self.needsAccessibility { self.needsAccessibility = missing }
      }
    }
  }

  /// Takes one event from the shortcut monitor.
  public func handle(_ event: ShortcutEvent) {
    switch event {
    case .down(let action): pressed(action)
    case .up(let action): released(action)
    case .abandoned(let action, let next): abandoned(action, replacedBy: next)
    case .cancel:
      held = nil
      endsOnRelease = false
      cancel()
    }
  }

  private func pressed(_ action: ShortcutAction) {
    switch action {
    case .pushToTalk:
      if model.dictation.isRecording {
        // A hands-free recording is running: this key ends it, once we know the press was
        // meant for us (it is let go again) and not the start of fn + arrow.
        endsOnRelease = true
      } else if begin(.dictation, handsFree: false, quietly: true) {
        held = action
      }
    case .commandMode:
      if begin(.command, handsFree: false, quietly: false) { held = action }
    case .handsFree: toggleHandsFree()
    case .pasteLast: pasteLast()
    case .toggleMeeting: toggleMeeting()
    }
  }

  private func released(_ action: ShortcutAction) {
    if action == .pushToTalk, endsOnRelease {
      endsOnRelease = false
      finish()
      return
    }
    guard held == action else { return }
    held = nil
    finish()
  }

  private func abandoned(_ action: ShortcutAction, replacedBy next: ShortcutAction?) {
    if action == .pushToTalk, endsOnRelease {
      // The press became something else. A longer shortcut of ours gets its own `down` next.
      endsOnRelease = false
      return
    }
    guard held == action else { return }
    held = nil
    reveal?.cancel()
    carriesOver = next != nil && showsRecording
    if !carriesOver { showsRecording = false }
    run += 1
    isWrappingUp = false
    model.dictation.cancel()
  }

  // MARK: - Dictation

  /// Starts a hands-free dictation, or ends the recording that is running.
  public func toggleHandsFree() {
    switch model.dictation.phase {
    case .recording: finish()
    case .processing: break
    case .idle, .failed: begin(.dictation, handsFree: true, quietly: false)
    }
  }

  /// Ends the recording and turns it into text.
  public func finish() {
    guard model.dictation.isRecording, !isWrappingUp else { return }
    reveal?.cancel()
    if showsRecording { play(.stop) }
    isWrappingUp = true
    let run = run
    Task { [weak self, model] in
      await model.dictation.finish()
      guard let self, self.run == run else { return }
      self.isWrappingUp = false
    }
  }

  /// Throws the recording away, or stops the text being made.
  public func cancel() {
    reveal?.cancel()
    carriesOver = false
    showsRecording = false
    isWrappingUp = false
    run += 1
    model.dictation.cancel()
  }

  /// Types the most recent dictation again.
  public func pasteLast() {
    Task { [model] in await model.dictation.pasteLast() }
  }

  @discardableResult
  private func begin(_ mode: DictationMode, handsFree: Bool, quietly: Bool) -> Bool {
    let carried = carriesOver
    carriesOver = false
    switch model.dictation.phase {
    case .recording, .processing: return false
    case .idle, .failed: break
    }
    guard !needsKey else {
      showsRecording = false
      show(Notice(message: "Add your OpenAI key", fix: .settings))
      play(.error)
      return false
    }
    clearNotice()
    run += 1
    isWrappingUp = false
    model.dictation.start(mode: mode, handsFree: handsFree)
    reveal?.cancel()
    if carried {
      showsRecording = true
    } else if quietly {
      showsRecording = false
      let run = run
      reveal = Task { [weak self, revealDelay] in
        try? await Task.sleep(for: revealDelay)
        guard !Task.isCancelled, let self, self.run == run else { return }
        self.revealRecording()
      }
    } else {
      showsRecording = false
      revealRecording()
    }
    return true
  }

  private func revealRecording() {
    guard model.dictation.isRecording, !showsRecording else { return }
    showsRecording = true
    play(.start)
  }

  /// OpenAI itself needs a key. A server of the user's own may not.
  private var needsKey: Bool {
    let server = (model.settings.apiBaseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return !model.hasAPIKey && server.isEmpty
  }

  private func phaseChanged(to phase: DictationEngine.Phase) {
    defer { lastPhase = phase }
    switch phase {
    case .recording:
      monitor?.cancelsOnEscape = true
    case .processing:
      monitor?.cancelsOnEscape = true
      // The engine ended the recording by itself (it ran too long): mark that too.
      if case .recording = lastPhase, showsRecording, !isWrappingUp { play(.stop) }
    case .idle:
      monitor?.cancelsOnEscape = false
      if !carriesOver { showsRecording = false }
    case .failed(let message):
      monitor?.cancelsOnEscape = false
      showsRecording = false
      show(Notice(message: message, fix: Self.fix(for: message)))
      play(.error)
    }
  }

  /// What a click should do about a failure, told from its message.
  nonisolated static func fix(for message: String) -> Notice.Fix? {
    for error in [WisperError.missingAPIKey, .invalidAPIKey] where message == error.errorDescription {
      return .settings
    }
    for permission in Permission.allCases {
      if let text = WisperError.permissionDenied(permission).errorDescription, message.hasPrefix(text) {
        return .permission(permission)
      }
    }
    return nil
  }

  // MARK: - Meetings

  /// Starts a meeting recording, or stops the one that is running.
  public func toggleMeeting() {
    let wasRecording = model.meetings.isRecording
    Task { [weak self, model] in
      await model.meetings.toggle()
      guard let self else { return }
      if model.meetings.isRecording != wasRecording { self.play(wasRecording ? .stop : .start) }
      // A start clears the engine's message first, so anything there now is news.
      if !wasRecording, let problem = model.meetings.lastError {
        self.show(Notice(message: problem, fix: .hub))
        if !model.meetings.isRecording { self.play(.error) }
      }
    }
  }

  // MARK: - Notices and the pill

  /// Takes the notice away (and the failure behind it).
  public func dismissNotice() {
    clearNotice()
    model.dictation.dismissFailure()
  }

  /// Does what the notice suggests: opens Settings, asks for the permission or shows the hub.
  /// A notice with nothing to fix is just dismissed.
  public func fixNotice() {
    let fix = notice?.fix
    dismissNotice()
    switch fix {
    case .settings: open(.settings)
    case .hub: open(.hub)
    case .permission(let permission): requestPermission(permission)
    case nil: break
    }
  }

  /// Asks for a permission the way the system allows: its prompt the first time, System Settings after.
  public func requestPermission(_ permission: Permission) {
    Task { [model] in _ = await model.permissions.request(permission) }
  }

  /// Keeps the idle pill out of sight for a while. `nil` brings it back now.
  public func hidePill(for time: Duration?) {
    pillTimer?.cancel()
    guard let time else {
      pillHiddenUntil = nil
      return
    }
    let seconds = Double(time.components.seconds)
    pillHiddenUntil = Date().addingTimeInterval(seconds)
    pillTimer = Task { [weak self] in
      try? await Task.sleep(for: time)
      guard !Task.isCancelled else { return }
      self?.pillHiddenUntil = nil
    }
  }

  private func show(_ notice: Notice) {
    self.notice = notice
    noticeTimer?.cancel()
    noticeTimer = Task { [weak self, noticeTime] in
      try? await Task.sleep(for: noticeTime)
      guard !Task.isCancelled else { return }
      self?.dismissNotice()
    }
  }

  private func clearNotice() {
    noticeTimer?.cancel()
    noticeTimer = nil
    notice = nil
  }

  private func play(_ cue: SoundCue) {
    sounds?.play(cue, enabled: model.settings.playSounds)
  }
}
