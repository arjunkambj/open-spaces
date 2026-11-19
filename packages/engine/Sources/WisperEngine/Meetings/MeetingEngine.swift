import Foundation
import Observation
import WisperDomain

/// Records a meeting and turns it into a transcript and notes.
///
/// `start` begins recording into a new `Meeting`; audio is cut into chunks
/// that are transcribed while the meeting is still going. `stop` finishes the
/// transcript and writes the notes. Views observe `live` and `level`.
@MainActor
@Observable
public final class MeetingEngine {
  /// The meeting being recorded right now.
  public struct Live: Equatable, Sendable {
    public var meetingID: Meeting.ID
    public var title: String
    public var startedAt: Date
    /// Transcript so far, oldest first.
    public var segments: [TranscriptSegment]

    public init(meetingID: Meeting.ID, title: String, startedAt: Date, segments: [TranscriptSegment] = []) {
      self.meetingID = meetingID
      self.title = title
      self.startedAt = startedAt
      self.segments = segments
    }
  }

  public private(set) var live: Live?
  /// Loudness while recording, 0...1.
  public private(set) var level: Float = 0
  /// Meetings whose transcript or notes are being made after `stop`.
  public private(set) var processing: Set<Meeting.ID> = []

  public init(
    library: any Library,
    capture: any AudioCapture,
    transcriber: any Transcriber,
    languageModel: any LanguageModel
  ) {
    // CONTRACT STUB: the meeting engine piece replaces this file's bodies.
  }

  public var isRecording: Bool { live != nil }

  /// Starts recording a new meeting and returns its ID. `title` defaults to a
  /// dated placeholder that is replaced by a generated title when notes are written.
  /// Throws `WisperError` when capture cannot start or a meeting is already being recorded.
  @discardableResult
  public func start(title: String? = nil) async throws -> Meeting.ID {
    throw WisperError.captureFailed("not implemented")
  }

  /// Stops recording. Returns once the meeting is saved as `.processing`;
  /// the transcript and notes are finished in the background and the meeting
  /// then becomes `.ready` (or `.failed`).
  public func stop() async {}

  /// Starts a meeting when none is being recorded, stops it otherwise.
  public func toggle() async {}

  /// Writes the AI notes for a meeting again from its transcript.
  public func regenerateNotes(_ id: Meeting.ID) async throws {}

  /// Processes a `.failed` meeting again from its kept audio.
  public func retry(_ id: Meeting.ID) async throws {}

  /// Answers a question using only this meeting's transcript and notes.
  public func ask(_ question: String, about id: Meeting.ID) async throws -> String { "" }

  /// Call once at launch: meetings left in `.recording` or `.processing` by a
  /// crash or quit are finished from the audio on disk.
  public func recoverUnfinished() async {}
}
