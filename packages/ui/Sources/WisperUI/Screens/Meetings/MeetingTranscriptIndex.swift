import CoreTransferable
import Foundation
import WisperDomain

/// The turns of a meeting's transcript and the matches of the text being looked for, worked out
/// once and remembered. A meeting's page asks for both each time it is drawn, which is many
/// times a second while someone types; only a changed transcript or new text costs anything.
@MainActor
final class MeetingTranscriptIndex {
  private var segments: [TranscriptSegment] = []
  private var grouped: [TranscriptTurn] = []
  private var query = ""
  private var found: [TranscriptMatch] = []

  /// The transcript as turns. See `MeetingsLogic.turns`.
  func turns(of segments: [TranscriptSegment]) -> [TranscriptTurn] {
    // Comparing with the transcript seen last costs nothing while it is the very same array,
    // which it is between two changes of the library.
    if segments != self.segments {
      self.segments = segments
      grouped = MeetingsLogic.turns(segments)
      found = MeetingsLogic.matches(of: query, in: grouped)
    }
    return grouped
  }

  /// Every place `query` appears in the transcript, from top to bottom.
  func matches(of query: String, in segments: [TranscriptSegment]) -> [TranscriptMatch] {
    let turns = turns(of: segments)
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if query != self.query {
      self.query = query
      found = MeetingsLogic.matches(of: query, in: turns)
    }
    return found
  }
}

/// A meeting handed to the share sheet. Its Markdown is written when something asks for it,
/// not each time the page that shows the Share button is drawn.
struct MeetingShare: Transferable {
  let meeting: Meeting

  static var transferRepresentation: some TransferRepresentation {
    ProxyRepresentation { share in share.meeting.markdown() }
  }
}
