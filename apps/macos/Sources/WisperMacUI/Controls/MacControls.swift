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
/// - A held push to talk that grows into hands-free or command mode (fn, then
///   Space or ⌃) stays one recording: the microphone is not reopened, nothing
///   said so far is lost and the start sound plays once.
/// - A press never does nothing without a sign. While the last dictation is
///   still being written, a held key waits and starts recording as soon as it
///   can; if that takes more than a moment, a notice says so.
/// - Escape throws a recording away. Once text is being written it is left
///   alone, and Escape goes to the app in front as usual.
/// - Nothing is recorded without an OpenAI key (unless a custom server is
///   set): a notice says what to do instead.
/// - A meeting that a link started always plays the start sound, also with
///   sounds switched off.
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
      /// Open System Settings at Login Items.
      case loginItems
    }

    public var message: String
    public var fix: Fix?
    /// False for a message that is only news ("Copied to the clipboard") and not something gone wrong.
    public var isProblem: Bool

    public init(message: String, fix: Fix? = nil, isProblem: Bool = true) {
      self.message = message
      self.fix = fix
      self.isProblem = isProblem
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
  /// Plays a sound. Only called for sounds that should really be heard.
  @ObservationIgnored private let sound: @MainActor (SoundCue) -> Void
  @ObservationIgnored private let revealDelay: Duration
  @ObservationIgnored private let noticeTime: Duration
  /// How long a held key waits for the last dictation before a notice says why nothing is recorded yet.
  @ObservationIgnored var busyNoticeDelay: Duration = .milliseconds(600)

  /// The hold action (push to talk, command mode) whose key is down and whose release ends the recording.
  @ObservationIgnored private var held: ShortcutAction?
  /// Push to talk went down while a recording was running: letting it go ends that recording.
  @ObservationIgnored private var endsOnRelease = false
  /// The hold action whose key went down while the last dictation was still being finished.
  /// It starts as soon as the engine is free, if the key is still down then.
  @ObservationIgnored private var waiting: ShortcutAction?
  @ObservationIgnored private var waitNotice: Task<Void, Never>?
  /// The longer shortcut a held push to talk has just grown into. Its `down` comes next and is already dealt with.
  @ObservationIgnored private var grewInto: ShortcutAction?
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
  public convenience init(
    model: AppModel,
    monitor: ShortcutMonitor? = nil,
    sounds: SoundPlayer? = nil,
    revealDelay: Duration = .milliseconds(150),
    noticeTime: Duration = .seconds(5)
  ) {
    self.init(model: model, monitor: monitor, revealDelay: revealDelay, noticeTime: noticeTime) { cue in
      sounds?.play(cue)
    }
  }

  /// - sound: plays one sound; tests pass a closure that only writes the sounds down.
  init(
    model: AppModel,
    monitor: ShortcutMonitor? = nil,
    revealDelay: Duration,
    noticeTime: Duration,
    sound: @escaping @MainActor (SoundCue) -> Void
  ) {
    self.model = model
    self.monitor = monitor
    self.sound = sound
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
    let grown = grewInto
    grewInto = nil
    switch event {
    case .down(let action) where action == grown: break
    case .down(let action): pressed(action)
    case .up(let action): released(action)
    case .abandoned(let action, let next): abandoned(action, replacedBy: next)
    case .cancel: escaped()
    }
  }

  private func pressed(_ action: ShortcutAction) {
    switch action {
    case .pushToTalk:
      if case .recording(_, _, true) = model.dictation.phase, !isWrappingUp {
        // A hands-free recording is running: this key ends it, once we know the press was
        // meant for us (it is let go again) and not the start of fn + arrow.
        endsOnRelease = true
      } else {
        hold(action)
      }
    case .commandMode: hold(action)
    case .handsFree: toggleHandsFree()
    case .pasteLast: pasteLast()
    case .toggleMeeting: toggleMeeting()
    }
  }

  private func released(_ action: ShortcutAction) {
    if waiting == action {
      stopWaiting()
      return
    }
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
    if waiting == action {
      stopWaiting()
      return
    }
    if action == .pushToTalk, endsOnRelease {
      // The press became something else. A longer shortcut of ours gets its own `down` next.
      endsOnRelease = false
      return
    }
    guard held == action else { return }
    held = nil
    if let next, grow(into: next) { return }
    // The keys were meant for something else: throw away what `down` started.
    reveal?.cancel()
    showsRecording = false
    run += 1
    isWrappingUp = false
    model.dictation.cancel()
  }

  /// Escape. Drops a press that was waiting, or throws the recording away.
  /// Text that is already being written is left alone.
  private func escaped() {
    held = nil
    endsOnRelease = false
    if waiting != nil {
      stopWaiting()
      return
    }
    guard model.dictation.isRecording, !isWrappingUp else { return }
    cancel()
  }

  /// Starts recording for a hold action, or remembers the press while the last dictation is being finished.
  private func hold(_ action: ShortcutAction) {
    switch model.dictation.phase {
    case .recording where !isWrappingUp:
      // A recording is running and showing. This key has no job until it is over.
      break
    case .recording, .processing:
      wait(for: action)
    case .idle, .failed:
      let isCommand = action == .commandMode
      if begin(isCommand ? .command : .dictation, handsFree: false, quietly: !isCommand) { held = action }
    }
  }

  /// Turns the held recording that is running into the longer shortcut the keys grew into,
  /// without closing the microphone. False when there is nothing to carry on with.
  private func grow(into next: ShortcutAction) -> Bool {
    guard model.dictation.isRecording, !isWrappingUp else { return false }
    switch next {
    case .handsFree:
      model.dictation.change(mode: .dictation, handsFree: true)
    case .commandMode, .pushToTalk:
      model.dictation.change(mode: next == .commandMode ? .command : .dictation, handsFree: false)
      held = next
    case .pasteLast, .toggleMeeting:
      return false
    }
    grewInto = next
    // It is certainly meant now: show it at once. The sound plays only if it has not yet.
    reveal?.cancel()
    revealRecording()
    return true
  }

  // MARK: - A press while the engine is busy

  private func wait(for action: ShortcutAction) {
    waiting = action
    waitNotice?.cancel()
    waitNotice = Task { [weak self, busyNoticeDelay] in
      try? await Task.sleep(for: busyNoticeDelay)
      guard !Task.isCancelled, let self, self.waiting == action else { return }
      self.sayBusy("Still writing the last one. Not listening yet.")
    }
  }

  private func stopWaiting() {
    waiting = nil
    waitNotice?.cancel()
    waitNotice = nil
  }

  /// Starts the press that was waiting, if the engine is free now.
  private func resume() {
    guard let action = waiting else { return }
    switch model.dictation.phase {
    case .recording, .processing:
      break
    case .idle, .failed:
      // After a failure too: the key is down and the person is talking. The failed one is in history.
      stopWaiting()
      hold(action)
    }
  }

  private func sayBusy(_ message: String) {
    show(Notice(message: message))
    play(.error)
  }

  // MARK: - Dictation

  /// Starts a hands-free dictation, or ends the recording that is running.
  public func toggleHandsFree() {
    switch model.dictation.phase {
    case .recording where isWrappingUp: sayBusy("Still writing the last one. Try again in a moment.")
    case .processing: sayBusy("Still writing the last one. Try again in a moment.")
    case .recording: finish()
    case .idle, .failed: begin(.dictation, handsFree: true, quietly: false)
    }
  }

  /// Ends the recording and turns it into text.
  public func finish() {
    guard model.dictation.isRecording, !isWrappingUp else { return }
    reveal?.cancel()
    if showsRecording { play(.stop) }
    isWrappingUp = true
    // From here on text is being written: Escape belongs to the app in front again.
    monitor?.cancelsOnEscape = false
    let run = run
    Task { [weak self, model] in
      await model.dictation.finish()
      guard let self, self.run == run else { return }
      self.isWrappingUp = false
      self.resume()
    }
  }

  /// Throws the recording away, or stops the text being made.
  public func cancel() {
    reveal?.cancel()
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
    showsRecording = false
    if quietly {
      let run = run
      reveal = Task { [weak self, revealDelay] in
        try? await Task.sleep(for: revealDelay)
        guard !Task.isCancelled, let self, self.run == run else { return }
        self.revealRecording()
      }
    } else {
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
      // Escape throws a recording away, also when no key is held (hands-free).
      monitor?.cancelsOnEscape = !isWrappingUp
    case .processing:
      // Text is being written. Escape is not ours to take: it would delete what was just said.
      monitor?.cancelsOnEscape = false
      // The engine ended the recording by itself (it ran too long): mark that too.
      if case .recording = lastPhase, showsRecording, !isWrappingUp { play(.stop) }
    case .idle:
      monitor?.cancelsOnEscape = false
      showsRecording = false
      resume()
    case .failed(let message):
      monitor?.cancelsOnEscape = false
      showsRecording = false
      show(Notice(message: message, fix: Self.fix(for: message)))
      play(.error)
      resume()
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
      if !wasRecording { self.showMeetingProblem() }
    }
  }

  /// Starts a meeting recording because a link asked for it. Does nothing while one is running.
  ///
  /// The start sound plays even when sounds are switched off: a recording that something
  /// outside the app started must never begin without a sign.
  public func startMeeting(title: String?) {
    guard !model.meetings.isRecording else { return }
    Task { [weak self, model] in
      do {
        try await model.meetings.start(title: title)
      } catch {
        self?.show(Notice(message: error.localizedDescription, fix: .hub))
        self?.play(.error)
        return
      }
      self?.sound(.start)
      self?.showMeetingProblem()
    }
  }

  private func showMeetingProblem() {
    guard let problem = model.meetings.lastError else { return }
    show(Notice(message: problem, fix: .hub))
    if !model.meetings.isRecording { play(.error) }
  }

  // MARK: - Open at login

  /// Brings the "Open at login" setting in line with what macOS really did, and says so
  /// when macOS did not do as asked.
  /// - status: what `LaunchAtLogin` reports now.
  /// - wanted: what the person just chose, or `nil` when only checking (at launch).
  public func noteLaunchAtLogin(_ status: LaunchAtLogin.Status, wanted: Bool? = nil) {
    if let isOn = Self.launchAtLoginSetting(for: status, wanted: wanted), model.settings.launchAtLogin != isOn
    {
      // A turn later, so this lands after the change that brought us here.
      Task { [model] in model.update { $0.launchAtLogin = isOn } }
    }
    guard wanted == true else { return }
    switch status {
    case .on:
      break
    case .needsApproval:
      show(Notice(message: "Allow Open Wisper in Login Items so it can open at login.", fix: .loginItems))
    case .off:
      show(
        Notice(message: "macOS did not let Open Wisper open at login. Check Login Items.", fix: .loginItems)
      )
    case .unavailable:
      show(Notice(message: "Open at login only works when Open Wisper runs as an app."))
    }
  }

  /// What the setting should say given what macOS reports, or `nil` to leave it as it is.
  nonisolated static func launchAtLoginSetting(for status: LaunchAtLogin.Status, wanted: Bool?) -> Bool? {
    switch status {
    case .on: true
    case .off: false
    // Asked for and waiting for the person's yes in System Settings: their choice stands.
    case .needsApproval: nil
    // Not the bundled app, so macOS cannot be asked. Only take back a choice just made.
    case .unavailable: wanted == true ? false : nil
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
    case .loginItems: LaunchAtLogin.openSettings()
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

  /// Says that text was put on the clipboard instead of typed, because no app was there to type into.
  public func noteCopied() {
    show(Notice(message: "Copied to the clipboard", isProblem: false))
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

  /// Plays `cue`, unless the person has switched sounds off.
  private func play(_ cue: SoundCue) {
    if model.settings.playSounds { sound(cue) }
  }
}
