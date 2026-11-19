import Foundation
import WisperDomain

/// The engine's own record of a meeting's audio, kept next to the audio files.
///
/// It lists every chunk capture has finished, where it sits in the meeting and what was heard in
/// it. That is what lets a meeting be finished after the app quit or a transcription failed.
struct MeetingManifest: Codable, Equatable, Sendable {
  static let fileName = "manifest.json"

  struct Chunk: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
      /// Not transcribed yet.
      case pending
      /// Transcribed. `segments` holds what was heard, which may be nothing.
      case done
      /// Every attempt failed. Waits for a retry.
      case failed
    }

    /// File name inside the meeting's audio folder.
    var file: String
    var track: AudioTrack
    /// Seconds from the start of the meeting.
    var offset: TimeInterval
    var duration: TimeInterval
    var state: State = .pending
    /// What was heard, with times counted from the start of the meeting.
    var segments: [TranscriptSegment] = []
  }

  var version = 1
  var chunks: [Chunk] = []

  /// The manifest in `directory`, or `nil` when there is none that can be read.
  static func read(from directory: URL) -> MeetingManifest? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
    return try? JSONDecoder().decode(MeetingManifest.self, from: data)
  }

  /// Replaces the manifest in `directory` in one step, so a crash never leaves half a file.
  func write(to directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(
      to: directory.appendingPathComponent(MeetingManifest.fileName),
      options: .atomic
    )
  }
}
