import Foundation
import Observation
import WisperDomain

/// Runs a dictation from the first key press to inserted text.
///
/// `start` begins recording, `finish` turns the recording into text and puts
/// it into the target, `cancel` throws it away. Everything in between
/// (capture, transcription, dictionary, clean-up, snippets, history) happens
/// inside. Views observe `phase` and `level`.
@MainActor
@Observable
public final class DictationEngine {
  public enum Phase: Equatable, Sendable {
    case idle
    /// Recording. `handsFree` means it keeps going until `finish()` is called
    /// (as opposed to ending when the key is released).
    case recording(mode: DictationMode, since: Date, handsFree: Bool)
    /// Recording is over; text is being made.
    case processing(mode: DictationMode)
    /// The last dictation failed. Cleared by the next `start` or by `dismissFailure`.
    case failed(message: String)
  }

  public private(set) var phase: Phase = .idle
  /// Microphone loudness while recording, 0...1.
  public private(set) var level: Float = 0
  /// The most recent finished dictation of this session.
  public private(set) var last: Dictation?

  public init(
    library: any Library,
    capture: any AudioCapture,
    transcriber: any Transcriber,
    languageModel: any LanguageModel,
    target: any TextTarget
  ) {
    // CONTRACT STUB: the dictation engine piece replaces this file's bodies.
  }

  /// Starts recording. Does nothing unless `phase` is `.idle` or `.failed`.
  public func start(mode: DictationMode = .dictation, handsFree: Bool = false) {}

  /// Stops recording, makes the text and inserts it into the target.
  /// Returns the saved dictation, or `nil` when nothing was recorded, no
  /// speech was heard, or it failed (then `phase` is `.failed`).
  @discardableResult
  public func finish() async -> Dictation? { nil }

  /// Stops recording and discards the audio.
  public func cancel() {}

  /// Runs a failed dictation's kept audio through the pipeline again.
  @discardableResult
  public func retry(_ id: Dictation.ID) async -> Dictation? { nil }

  /// Inserts the most recent dictation from history into the target again.
  public func pasteLast() async {}

  public func dismissFailure() {}

  public var isRecording: Bool {
    if case .recording = phase { return true }
    return false
  }

  public var isBusy: Bool { phase != .idle }
}
