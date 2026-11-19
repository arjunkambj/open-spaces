import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
import WisperDomain

@testable import WisperUI

@Suite("Meetings: the transcript is grouped and searched once")
@MainActor
struct MeetingTranscriptIndexTests {
  private static func segment(_ speaker: Speaker, _ start: TimeInterval, _ text: String) -> TranscriptSegment
  {
    TranscriptSegment(speaker: speaker, start: start, end: start + 5, text: text)
  }

  private static let talk = [
    segment(.me, 0, "Let's talk about billing."),
    segment(.others, 8, "The billing move is next weekend."),
    segment(.me, 20, "Good."),
  ]

  /// Counts how often the transcript is grouped.
  private final class Counter {
    var runs = 0
  }

  private func index(counting counter: Counter) -> MeetingTranscriptIndex {
    MeetingTranscriptIndex { segments in
      counter.runs += 1
      return MeetingsLogic.turns(segments)
    }
  }

  @Test func groupsTheSameTranscriptOnlyOnce() {
    let counter = Counter()
    let index = index(counting: counter)
    let first = index.turns(of: Self.talk)
    // Drawn again and again, as while someone types in the find field.
    for _ in 0..<50 { _ = index.turns(of: Self.talk) }
    _ = index.matches(of: "bil", in: Self.talk)
    _ = index.matches(of: "billing", in: Self.talk)
    #expect(counter.runs == 1)
    #expect(first == MeetingsLogic.turns(Self.talk))
  }

  @Test func groupsAgainWhenTheTranscriptChanges() {
    let counter = Counter()
    let index = index(counting: counter)
    _ = index.turns(of: Self.talk)
    let longer = Self.talk + [Self.segment(.others, 30, "One more thing about billing.")]
    #expect(index.turns(of: longer) == MeetingsLogic.turns(longer))
    #expect(counter.runs == 2)
    // The matches follow the new transcript without being asked for new text.
    #expect(index.matches(of: "billing", in: longer).count == 3)
    #expect(counter.runs == 2)
  }

  @Test func findsTheSameMatchesAsSearchingFromScratch() {
    let index = MeetingTranscriptIndex()
    let turns = MeetingsLogic.turns(Self.talk)
    #expect(index.matches(of: " billing ", in: Self.talk) == MeetingsLogic.matches(of: "billing", in: turns))
    #expect(index.matches(of: "", in: Self.talk).isEmpty)
    #expect(index.matches(of: "zebra", in: Self.talk).isEmpty)
    #expect(index.matches(of: "good", in: Self.talk).count == 1)
  }

  @Test func aSharedMeetingIsWrittenAsMarkdownOnlyWhenAskedFor() async throws {
    // Reading what a share would hand over needs a newer system than the app does.
    guard #available(macOS 15.2, iOS 18.2, *) else { return }
    let meeting = Meeting(title: "Weekly sync", status: .ready, segments: Self.talk)
    let data = try await MeetingShare(meeting: meeting).exported(as: .utf8PlainText)
    #expect(String(decoding: data, as: UTF8.self) == meeting.markdown())
  }
}
