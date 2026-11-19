import Foundation
import Observation
import WisperDomain
import WisperEngine

/// Dictation the way the phone does it: tap, speak, tap, and the text is on the clipboard.
///
/// It sits between the Dictate screen and `DictationEngine`. The engine records and makes
/// the text; this adds what only the phone needs: asking for the microphone at the right
/// moment, checking that a key is there before anyone speaks, push to talk, and saying in
/// plain words why there is no text when there is none.
@MainActor
@Observable
public final class PhoneDictation {
  /// Why there is no text, or cannot be any.
  public enum Problem: Equatable, Sendable {
    /// No OpenAI key has been added yet.
    case missingKey
    /// The person said no to the microphone. Only the Settings app can change that.
    case microphoneDenied
    /// The recording held no speech.
    case nothingHeard
    /// Something went wrong. `retry` is the history entry whose audio was kept, when
    /// trying again is possible.
    case failed(message: String, retry: Dictation.ID?)
  }

  /// Goes up each time text is put on the clipboard, so a screen can say "Copied".
  public private(set) var copies = 0

  @ObservationIgnored private let model: AppModel
  @ObservationIgnored private let clipboard: Clipboard

  private var microphoneDenied = false
  private var nothingHeard = false
  /// A reason recording could not start that is not a lasting state of the phone.
  private var refusal: String?
  /// The latest result after the person edited it.
  private var edited: Dictation?
  /// When the current or last recording began. Tells this attempt's failed entry from older ones.
  private var startedAt: Date?
  @ObservationIgnored private var isHolding = false
  @ObservationIgnored private var isStopping = false
  @ObservationIgnored private var wasCancelled = false

  public init(model: AppModel, clipboard: Clipboard) {
    self.model = model
    self.clipboard = clipboard
  }

  // MARK: What to show

  public var phase: DictationEngine.Phase { model.dictation.phase }

  /// Microphone loudness while recording, 0...1.
  public var level: Double { Double(model.dictation.level) }

  public var isRecording: Bool { model.dictation.isRecording }

  /// The newest text made since the app started.
  public var result: Dictation? {
    guard let last = model.dictation.last else { return nil }
    return edited?.id == last.id ? edited : last
  }

  /// A few earlier dictations, newest first.
  public var earlier: [Dictation] {
    let shown = result?.id
    return Array(model.dictations.lazy.filter { !$0.failed && !$0.text.isEmpty && $0.id != shown }.prefix(4))
  }

  /// What stands between the person and their text right now, most pressing first.
  public var problem: Problem? {
    if needsKey { return .missingKey }
    if microphoneDenied { return .microphoneDenied }
    if let refusal { return .failed(message: refusal, retry: nil) }
    if case .failed(let message) = model.dictation.phase {
      return .failed(message: message, retry: retryCandidate)
    }
    return nothingHeard ? .nothingHeard : nil
  }

  // MARK: What the person does

  /// Starts recording when idle, finishes when recording. The tap on the big button.
  public func toggle() async {
    switch model.dictation.phase {
    case .recording: await stop()
    case .processing: break
    case .idle, .failed: await start()
    }
  }

  /// Starts recording, asking for the microphone first if nobody has asked yet.
  /// When recording cannot start, `problem` says why.
  public func start(handsFree: Bool = true) async {
    guard canStart, readyToRecord() else { return }
    switch model.permissions.status(.microphone) {
    case .granted:
      break
    case .notDetermined:
      let answer = await model.permissions.request(.microphone)
      microphoneDenied = answer == .denied
      // The world may have moved on while the system's question was up.
      guard answer == .granted, canStart else { return }
    case .denied:
      microphoneDenied = true
      return
    }
    begin(handsFree: handsFree)
  }

  /// Finishes the recording: makes the text and copies it.
  public func stop() async {
    guard model.dictation.isRecording, !isStopping else { return }
    isStopping = true
    isHolding = false
    wasCancelled = false
    let dictation = await model.dictation.finish()
    isStopping = false
    if dictation != nil {
      copies += 1
    } else if model.dictation.phase == .idle, !wasCancelled {
      nothingHeard = true
    }
  }

  /// Throws the recording away, or stops the text from being made.
  public func cancel() {
    wasCancelled = true
    isHolding = false
    model.dictation.cancel()
  }

  /// A finger stayed down on the button: push to talk. Recording runs until `holdEnded`.
  /// Does nothing when recording cannot start at once (a hold cannot answer a system question).
  public func holdBegan() {
    guard canStart, readyToRecord(), model.permissions.status(.microphone) == .granted else { return }
    begin(handsFree: false)
    isHolding = true
  }

  /// The finger came up after `holdBegan`.
  public func holdEnded() async {
    guard isHolding else { return }
    await stop()
  }

  /// Runs the failed dictation's kept audio again.
  public func retry() async {
    guard case .failed(_, let id?) = problem else { return }
    if await model.dictation.retry(id) != nil { copies += 1 }
  }

  /// Clears a "nothing heard" or failure notice.
  public func dismissProblem() {
    nothingHeard = false
    refusal = nil
    model.dictation.dismissFailure()
  }

  /// Puts a dictation's text on the clipboard.
  public func copy(_ dictation: Dictation) {
    clipboard.write(dictation.text)
    copies += 1
  }

  /// Replaces a dictation's text with the person's corrected version, in the history and
  /// on the clipboard.
  public func save(_ text: String, for dictation: Dictation) async {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text != dictation.text else { return }
    var changed = dictation
    changed.text = text
    if changed.id == model.dictation.last?.id { edited = changed }
    clipboard.write(text)
    copies += 1
    await model.attempt { model in try await model.library.save(changed) }
  }

  /// Sends the person to where the microphone can be turned on.
  public func fixMicrophone() async {
    await model.permissions.request(.microphone)
    refresh()
  }

  /// Looks at the microphone permission again. Call it when the app comes to the front:
  /// the person may have been in the Settings app.
  public func refresh() {
    microphoneDenied = model.permissions.status(.microphone) == .denied
  }

  // MARK: Inside

  private var canStart: Bool {
    switch model.dictation.phase {
    case .idle, .failed: !isStopping
    case .recording, .processing: false
    }
  }

  /// OpenAI needs a key. A server of the person's own may not.
  private var needsKey: Bool {
    let customServer = (model.settings.apiBaseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return model.isLoaded && !model.hasAPIKey && customServer.isEmpty
  }

  /// Clears the last attempt's notices and checks everything that needs no system question.
  private func readyToRecord() -> Bool {
    nothingHeard = false
    refusal = nil
    guard !needsKey else { return false }
    guard !model.meetings.isRecording else {
      // One microphone: a second recording would cut into the meeting's.
      refusal = "A meeting is being recorded. Stop it before you dictate."
      return false
    }
    return true
  }

  private func begin(handsFree: Bool) {
    startedAt = Date()
    wasCancelled = false
    model.dictation.start(mode: .dictation, handsFree: handsFree)
  }

  /// The failed history entry this attempt left behind, if it kept audio to try again with.
  private var retryCandidate: Dictation.ID? {
    guard let startedAt else { return nil }
    return model.dictations.first { entry in
      entry.failed && entry.audioFile != nil && entry.createdAt >= startedAt.addingTimeInterval(-1)
    }?.id
  }
}
