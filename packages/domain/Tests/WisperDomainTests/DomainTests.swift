import Foundation
import Testing

@testable import WisperDomain

@Test func settingsSurviveARoundTripAndTolerateMissingKeys() throws {
  var settings = Settings(userName: "Alex")
  settings.styles[.email] = .veryCasual
  settings.shortcuts[.pushToTalk] = KeyCombo(keyCode: 49, modifiers: [.option])
  let data = try JSONEncoder().encode(settings)
  #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)

  let sparse = try JSONDecoder().decode(Settings.self, from: Data(#"{"userName":"Sam"}"#.utf8))
  #expect(sparse.userName == "Sam")
  #expect(sparse.shortcuts == Settings.defaultShortcuts)
  #expect(sparse.transcriptionModel == Settings.defaultTranscriptionModel)
}

@Test func statsCountWordsSpeedAndStreak() {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let day: TimeInterval = 86_400
  let dictations = [
    Dictation(createdAt: now, rawText: "", text: "one two three four", duration: 2),
    Dictation(createdAt: now.addingTimeInterval(-day), rawText: "", text: "five six", duration: 1),
    Dictation(createdAt: now.addingTimeInterval(-3 * day), rawText: "", text: "old", duration: 1),
    Dictation(createdAt: now, rawText: "", text: "", duration: 9, failure: "offline"),
  ]
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = TimeZone(identifier: "UTC")!
  let stats = DictationStats(dictations, now: now, calendar: utc)
  #expect(stats.totalWords == 7)
  #expect(stats.dictationCount == 3)
  #expect(stats.dayStreak == 2)
  #expect(stats.wordsPerMinute == 105)
}

@Test func inMemoryLibraryStoresSearchesAndReportsChanges() async throws {
  let library: any Library = InMemoryLibrary()
  var changes = library.changes().makeAsyncIterator()
  try await library.save(DictionaryWord(text: "Kubernetes"))
  #expect(await changes.next() == .words)
  try await library.save(Dictation(rawText: "hello", text: "Hello there", duration: 1))
  try await library.save(Dictation(rawText: "bye", text: "Goodbye", duration: 1))
  #expect(try await library.dictations(search: "hello", limit: nil).count == 1)
  #expect(try await library.dictations(search: nil, limit: 1).count == 1)
  let meeting = Meeting(
    title: "Sync",
    segments: [TranscriptSegment(speaker: .others, start: 61, end: 65, text: "Ship it")]
  )
  try await library.save(meeting)
  #expect(try await library.meetings(search: "ship").map(\.id) == [meeting.id])
  #expect(meeting.transcriptText == "[01:01] Others: Ship it")
  try await library.updateSettings { $0.historyRetention = .never }
  try await library.save(Dictation(rawText: "x", text: "x", duration: 1))
  #expect(try await library.dictations().isEmpty)
}

@Test func fakeCaptureEmitsChunksPerTrack() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let capture = FakeAudioCapture()
  let session = try await capture.start(CaptureRequest(tracks: [.microphone, .system], directory: directory))
  await session.stop()
  var tracks: Set<AudioTrack> = []
  for await chunk in session.chunks { tracks.insert(chunk.track) }
  #expect(tracks == [.microphone, .system])
}

@Test func linksRoundTrip() {
  let id = UUID()
  let links: [WisperLink] = [
    .startMeeting(title: "Design review"), .startMeeting(title: nil), .stopMeeting, .showMeeting(id),
    .toggleDictation, .showHub,
  ]
  for link in links { #expect(WisperLink(link.url) == link) }
  #expect(WisperLink(URL(string: "https://example.com")!) == nil)
  #expect(WisperLink(URL(string: "openwisper://meetings/not-a-uuid")!) == nil)
}

@Test func meetingMarkdownHasEverySection() {
  let meeting = SampleData.meetings(now: Date(timeIntervalSince1970: 1_800_000_000))[0]
  let markdown = meeting.markdown(timeZone: TimeZone(identifier: "UTC")!)
  #expect(markdown.hasPrefix("# Weekly product sync\n"))
  for heading in [
    "## Summary", "## Key points", "## Decisions", "## Action items", "## My notes", "## Transcript",
  ] {
    #expect(markdown.contains(heading))
  }
  #expect(markdown.contains("- [x] Send onboarding copy to design (Jordan)"))
  #expect(markdown.contains("**Length:** 31 min"))
}

@Test func updateMeetingChangesInPlaceAndNeverRevivesADeletedMeeting() async throws {
  let library: any Library = InMemoryLibrary()
  let meeting = Meeting(title: "Sync")
  try await library.save(meeting)
  let updated = try await library.updateMeeting(meeting.id) { $0.tags = ["team"] }
  #expect(updated?.tags == ["team"])
  #expect(try await library.meeting(meeting.id)?.title == "Sync")
  try await library.deleteMeeting(meeting.id)
  #expect(try await library.updateMeeting(meeting.id) { $0.title = "Back" } == nil)
  #expect(try await library.meetings().isEmpty)
}

@Test func linkTicketsWorkOnceAndOnlyFromTheDataFolder() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tickets-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let ticket = try LinkTicket.issue(in: root)
  let url = WisperLink.startMeeting(title: "Standup").url(ticket: ticket)
  #expect(WisperLink(url) == .startMeeting(title: "Standup"))
  #expect(WisperLink.ticket(in: url) == ticket)
  #expect(LinkTicket.redeem(WisperLink.ticket(in: url), in: root))
  #expect(!LinkTicket.redeem(ticket, in: root))

  #expect(!LinkTicket.redeem(nil, in: root))
  #expect(!LinkTicket.redeem("made-up-by-a-web-page-0000000000000000", in: root))
  #expect(!LinkTicket.redeem("../../../../etc/passwd-0000000000000000000", in: root))
  let late = try LinkTicket.issue(in: root)
  #expect(!LinkTicket.redeem(late, in: root, now: Date().addingTimeInterval(LinkTicket.lifetime + 5)))

  #expect(WisperLink.startMeeting(title: nil).needsTrust)
  #expect(WisperLink.toggleDictation.needsTrust)
  #expect(!WisperLink.showHub.needsTrust)
}

@Test func linksCutLongTitlesAndBadTimesNeverCrash() {
  let long = String(repeating: "a", count: 5_000) + "\nsecond line"
  var parts = URLComponents(string: "openwisper://meetings/start")!
  parts.queryItems = [URLQueryItem(name: "title", value: long)]
  guard case .startMeeting(let title?) = WisperLink(parts.url!) else {
    Issue.record("the link did not parse")
    return
  }
  #expect(title.count == 120)
  #expect(!title.contains("\n"))

  let meeting = Meeting(
    title: "Odd times",
    endedAt: Date().addingTimeInterval(1e300),
    segments: [
      TranscriptSegment(speaker: .me, start: 1e300, end: .infinity, text: "a"),
      TranscriptSegment(speaker: .me, start: -.infinity, end: .nan, text: "b"),
      TranscriptSegment(speaker: .others, start: .nan, end: 2, text: "c"),
    ]
  )
  #expect(meeting.transcriptText.contains("Me: a"))
  #expect(meeting.markdown().contains("# Odd times"))
}
