import Foundation
import Testing
import WisperDomain

@testable import WisperUI

@Suite("Meetings: grouping, wording and transcript search")
struct MeetingsLogicTests {
  /// A fixed calendar, so the tests read the same on every machine: UTC, English, weeks start on Monday.
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    calendar.locale = Locale(identifier: "en_US")
    calendar.firstWeekday = 2
    return calendar
  }()

  private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date
  {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
      ?? Date()
  }

  /// Thursday 19 November 2026, noon.
  private static let now = date(2026, 11, 19)

  private static func meeting(_ title: String, _ start: Date) -> Meeting {
    Meeting(title: title, startedAt: start, status: .ready)
  }

  private static func segment(_ speaker: Speaker, _ start: TimeInterval, _ text: String) -> TranscriptSegment
  {
    TranscriptSegment(speaker: speaker, start: start, end: start + 5, text: text)
  }

  // MARK: Grouping

  @Test func groupsMeetingsUnderDateHeadingsInOrder() {
    let meetings = [
      Self.meeting("a", Self.date(2026, 11, 19, 9)),
      Self.meeting("b", Self.date(2026, 11, 19, 8)),
      Self.meeting("c", Self.date(2026, 11, 18, 17)),
      Self.meeting("d", Self.date(2026, 11, 16, 10)),
      Self.meeting("e", Self.date(2026, 11, 13, 10)),
      Self.meeting("f", Self.date(2026, 10, 2, 10)),
      Self.meeting("g", Self.date(2025, 11, 20, 10)),
    ]
    let groups = MeetingsLogic.groups(meetings, now: Self.now, calendar: Self.calendar)
    #expect(
      groups.map(\.title) == ["Today", "Yesterday", "This week", "November", "October", "November 2025"]
    )
    #expect(groups.map { $0.meetings.map(\.title) } == [["a", "b"], ["c"], ["d"], ["e"], ["f"], ["g"]])
  }

  @Test func aMeetingFromTheFutureCountsAsToday() {
    #expect(
      MeetingsLogic.heading(for: Self.date(2026, 11, 25), now: Self.now, calendar: Self.calendar) == "Today"
    )
  }

  @Test func lastSundayIsNotThisWeekWhenWeeksStartOnMonday() {
    let sunday = Self.date(2026, 11, 15)
    #expect(MeetingsLogic.heading(for: sunday, now: Self.now, calendar: Self.calendar) == "November")
  }

  @Test func saysWhenAsBrieflyAsTheHeadingAllows() {
    func when(_ date: Date) -> String {
      // The system puts a narrow space before "PM"; the tests do not care which space.
      MeetingsLogic.when(date, now: Self.now, calendar: Self.calendar)
        .replacingOccurrences(of: "\u{202F}", with: " ")
    }
    #expect(when(Self.date(2026, 11, 19, 14, 30)) == "2:30 PM")
    #expect(when(Self.date(2026, 11, 18, 9, 5)) == "9:05 AM")
    #expect(when(Self.date(2026, 11, 16, 14, 30)) == "Monday, 2:30 PM")
    #expect(when(Self.date(2026, 11, 3, 14, 30)) == "Nov 3, 2:30 PM")
    #expect(when(Self.date(2025, 11, 3, 14, 30)) == "Nov 3, 2025, 2:30 PM")
  }

  // MARK: Wording

  @Test func saysHowLongAMeetingWas() {
    #expect(MeetingsLogic.length(0) == nil)
    #expect(MeetingsLogic.length(20) == "Under 1 min")
    #expect(MeetingsLogic.length(1_860) == "31 min")
    #expect(MeetingsLogic.length(3_600) == "1 hr")
    #expect(MeetingsLogic.length(6_900) == "1 hr 55 min")
  }

  @Test func showsARunningTime() {
    #expect(MeetingsLogic.clock(-3) == "0:00")
    #expect(MeetingsLogic.clock(7) == "0:07")
    #expect(MeetingsLogic.clock(754) == "12:34")
    #expect(MeetingsLogic.clock(3_723) == "1:02:03")
  }

  @Test func previewsTheSummaryThenTheUsersNotesThenTheFirstWords() {
    var meeting = Meeting(title: "Sync", segments: [Self.segment(.me, 0, "  Hello\nthere. ")])
    #expect(MeetingsLogic.preview(of: meeting) == "Hello there.")
    meeting.userNotes = "Call\n\nSam"
    #expect(MeetingsLogic.preview(of: meeting) == "Call Sam")
    meeting.notes = MeetingNotes(summary: "The launch is on track.")
    #expect(MeetingsLogic.preview(of: meeting) == "The launch is on track.")
    #expect(MeetingsLogic.preview(of: Meeting(title: "Empty")) == nil)
  }

  @Test func countsActionItemsThatAreNotDone() {
    var meeting = Meeting(title: "Sync")
    #expect(MeetingsLogic.openActionItems(in: meeting) == 0)
    meeting.notes = MeetingNotes(actionItems: [
      ActionItem(text: "a"), ActionItem(text: "b", done: true), ActionItem(text: "c"),
    ])
    #expect(MeetingsLogic.openActionItems(in: meeting) == 2)
  }

  @Test func makesAFileNameThatIsSafeToSave() {
    #expect(MeetingsLogic.fileName(for: Meeting(title: "Q3/Q4: plans?")) == "Q3 Q4 plans")
    #expect(MeetingsLogic.fileName(for: Meeting(title: " / ")) == "Meeting")
  }

  @Test func splitsANoticeIntoTitleAndRest() {
    let both = MeetingsLogic.notice("Part of this meeting could not be transcribed. Try again in a moment.")
    #expect(both.title == "Part of this meeting could not be transcribed.")
    #expect(both.message == "Try again in a moment.")
    let one = MeetingsLogic.notice("Recording failed: no input device")
    #expect(one.title == "Recording failed: no input device")
    #expect(one.message == nil)
  }

  // MARK: Phase and problems

  @Test func tellsWhereAMeetingIsInItsLife() {
    let ready = Meeting(title: "a", status: .ready)
    let recording = Meeting(title: "b", status: .recording)
    #expect(MeetingsLogic.phase(of: recording, liveID: recording.id, processing: []) == .live)
    #expect(MeetingsLogic.phase(of: recording, liveID: nil, processing: []) == .interrupted)
    #expect(MeetingsLogic.phase(of: ready, liveID: nil, processing: [ready.id]) == .processing)
    #expect(
      MeetingsLogic.phase(of: Meeting(title: "c", status: .processing), liveID: nil, processing: [])
        == .processing
    )
    #expect(
      MeetingsLogic.phase(of: Meeting(title: "d", status: .failed), liveID: nil, processing: []) == .failed
    )
    #expect(MeetingsLogic.phase(of: ready, liveID: UUID(), processing: []) == .ready)
  }

  @Test func aFailedMeetingOffersARetry() {
    let meeting = Meeting(
      title: "a",
      status: .failed,
      failure: "This meeting could not be transcribed. Could not reach OpenAI."
    )
    let problem = MeetingsLogic.problem(of: meeting, phase: .failed)
    #expect(problem?.title == "This meeting could not be transcribed.")
    #expect(problem?.message == "Could not reach OpenAI.")
    #expect(problem?.remedy == .retry)
    #expect(problem?.isSevere == true)
  }

  @Test func aFailedMeetingWithoutAReasonStillSaysSomething() {
    let problem = MeetingsLogic.problem(of: Meeting(title: "a", status: .failed), phase: .failed)
    #expect(problem?.title == "This meeting could not be finished.")
    #expect(problem?.message?.isEmpty == false)
  }

  @Test func aPartlyTranscribedMeetingOffersARetry() {
    let meeting = Meeting(
      title: "a",
      status: .ready,
      failure: "Part of this meeting could not be transcribed. Try again in a moment."
    )
    let problem = MeetingsLogic.problem(of: meeting, phase: .ready)
    #expect(problem?.remedy == .retry)
    #expect(problem?.isSevere == false)
  }

  @Test func notesThatCouldNotBeWrittenOfferWritingThemAgain() {
    let meeting = Meeting(
      title: "a",
      status: .ready,
      failure: "The notes could not be written. OpenAI did not accept your API key."
    )
    let problem = MeetingsLogic.problem(of: meeting, phase: .ready)
    #expect(problem?.remedy == .writeNotes)
    #expect(problem?.actionTitle == "Write notes")
  }

  @Test func nothingIsWrongWithAFinishedOrBusyMeeting() {
    let failed = Meeting(title: "a", status: .failed, failure: "Old failure. Still here.")
    #expect(MeetingsLogic.problem(of: Meeting(title: "b", status: .ready), phase: .ready) == nil)
    #expect(MeetingsLogic.problem(of: failed, phase: .processing) == nil)
    #expect(MeetingsLogic.problem(of: failed, phase: .live) == nil)
    #expect(MeetingsLogic.problem(of: Meeting(title: "c"), phase: .interrupted)?.remedy == .retry)
  }

  // MARK: Tags

  @Test func readsTagsFromWhatWasTyped() {
    #expect(MeetingsLogic.tags(from: " #Customer,  big   deal ,, customer ") == ["customer", "big deal"])
    #expect(MeetingsLogic.tags(from: "  ,# ") == [])
  }

  @Test func addsOnlyTagsThatAreNotThereYet() {
    #expect(MeetingsLogic.adding("Product, launch", to: ["product"]) == ["product", "launch"])
    #expect(MeetingsLogic.adding("", to: ["product"]) == ["product"])
  }

  // MARK: Transcript

  @Test func groupsWhatOneSpeakerSaysInARow() {
    let segments = [
      Self.segment(.me, 0, "One."),
      Self.segment(.me, 6, " Two. "),
      Self.segment(.others, 12, "Three."),
      Self.segment(.others, 18, "   "),
      Self.segment(.me, 24, "Four."),
    ]
    let turns = MeetingsLogic.turns(segments)
    #expect(turns.map(\.speaker) == [.me, .others, .me])
    #expect(turns.map { $0.segments.map(\.text) } == [["One.", "Two."], ["Three."], ["Four."]])
    #expect(turns.map(\.start) == [0, 12, 24])
    #expect(turns.first?.id == segments[0].id)
  }

  @Test func putsSegmentsInTheOrderTheyWereSaid() {
    let turns = MeetingsLogic.turns([
      Self.segment(.others, 30, "Second."), Self.segment(.me, 2, "First."),
    ])
    #expect(turns.flatMap(\.segments).map(\.text) == ["First.", "Second."])
  }

  @Test func cutsALongTurnSoItGetsANewTimeStamp() {
    let segments = (0..<5).map { Self.segment(.me, TimeInterval($0) * 50, "Part \($0).") }
    let turns = MeetingsLogic.turns(segments)
    #expect(turns.map(\.start) == [0, 150])
    #expect(turns.map(\.segments.count) == [3, 2])
  }

  @Test func findsTextWhateverItsCaseOrAccents() {
    let text = "The café bill. BILLING moved; no Cafe today."
    #expect(MeetingsLogic.ranges(of: "bill", in: text).map { String(text[$0]) } == ["bill", "BILL"])
    #expect(MeetingsLogic.ranges(of: "cafe", in: text).map { String(text[$0]) } == ["café", "Cafe"])
    #expect(MeetingsLogic.ranges(of: "  ", in: text).isEmpty)
    #expect(MeetingsLogic.ranges(of: "aa", in: "aaaa").count == 2)
  }

  @Test func listsMatchesFromTopToBottom() {
    let segments = [
      Self.segment(.me, 0, "Billing first."),
      Self.segment(.others, 10, "No match here."),
      Self.segment(.me, 20, "More billing, and billing again."),
    ]
    let turns = MeetingsLogic.turns(segments)
    let matches = MeetingsLogic.matches(of: "billing", in: turns)
    #expect(matches.map(\.segment) == [segments[0].id, segments[2].id, segments[2].id])
    #expect(matches.map(\.turn) == [turns[0].id, turns[2].id, turns[2].id])
    #expect(MeetingsLogic.matches(of: " ", in: turns).isEmpty)
  }

  @Test func stepsThroughMatchesAndGoesRoundAtTheEnds() {
    #expect(MeetingsLogic.step(0, by: 1, count: 3) == 1)
    #expect(MeetingsLogic.step(2, by: 1, count: 3) == 0)
    #expect(MeetingsLogic.step(0, by: -1, count: 3) == 2)
    #expect(MeetingsLogic.step(4, by: 1, count: 0) == 0)
  }
}
