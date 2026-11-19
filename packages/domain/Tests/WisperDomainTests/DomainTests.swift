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

@Test func dictationTimingsRoundTripAndNeverCostAnEntry() throws {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let timing = Dictation.Timing(path: .live, captureMs: 120, transcribeMs: 640, insertMs: 12, totalMs: 801)
  let dictation = Dictation(rawText: "hi", text: "Hi", duration: 1, timing: timing)

  let back = try decoder.decode(Dictation.self, from: encoder.encode(dictation))
  #expect(back.timing == timing)
  #expect(back.timing?.cleanUpMs == nil)

  // An entry from before timings were kept.
  let plain = try decoder.decode(
    Dictation.self,
    from: encoder.encode(Dictation(rawText: "", text: "x", duration: 1))
  )
  #expect(plain.timing == nil)

  // Written by a newer version, or by hand: what cannot be read is left out, and the entry stays.
  func entry(timing: String) throws -> Dictation {
    let json = """
      {"id": "00000000-0000-4000-8000-000000000001", "createdAt": "2026-11-19T09:00:00Z",
       "rawText": "hi", "text": "Hi", "duration": 1, "timing": \(timing)}
      """
    return try decoder.decode(Dictation.self, from: Data(json.utf8))
  }
  let odd = try entry(
    timing: #"{"path": "telepathy", "transcribeMs": 12.6, "insertMs": "soon", "totalMs": -4, "more": 1}"#
  )
  #expect(odd.timing == Dictation.Timing(transcribeMs: 13))
  #expect(try entry(timing: #""fast""#).timing == nil)
  #expect(try entry(timing: "null").text == "Hi")
}

@Test func aServerThatDoesNotAnswerIsNotCalledAnInternetProblem() throws {
  #expect(
    WisperError.noAnswer.errorDescription
      == "OpenAI did not answer in time, even on a second try. Try again in a moment."
  )
  let local = try APIServer(address: "http://localhost:11434")
  #expect(
    WisperError.noAnswer.message(server: local)
      == "localhost did not answer in time, even on a second try. Check that the server is running"
      + " and the address in Settings is right."
  )
  // Still a network error to code that sorts errors by kind.
  if case .network = WisperError.noAnswer {} else { Issue.record("noAnswer must be a network error") }
}

@Test func theFakeTranscriberCountsGettingReady() async {
  let fake = FakeTranscriber(text: "hi")
  let transcriber: any Transcriber = fake
  await transcriber.prepare()
  await transcriber.prepare()
  #expect(fake.preparations == 2)
}

@Test func theFakeCaptureHandsOverLiveSoundOnlyWhenAsked() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let capture = FakeAudioCapture(stopDuration: 2)

  let asked = try await capture.start(CaptureRequest(directory: directory, liveFrames: true))
  await asked.stop()
  var samples = 0
  for await frames in asked.frames { samples += frames.samples.count }
  // As much sound as the file it wrote is long.
  #expect(samples == 2 * 16_000)

  let plain = try await capture.start(CaptureRequest(directory: directory))
  await plain.stop()
  var any = false
  for await _ in plain.frames { any = true }
  #expect(!any)
}

@Test func theFakeLiveTranscriberRemembersWhatItWasHanded() async throws {
  let fake = FakeLiveTranscriber { session in Transcript(text: "\(session.sampleCount) samples") }
  let live: any LiveTranscriber = fake

  let session = try await live.open(
    LiveTranscriptionRequest(model: "m", language: "en", vocabulary: ["Acme"])
  )
  session.send(AudioFrames(samples: [0, 0.5, -0.5], sampleRate: 16_000))
  session.send(AudioFrames(samples: [0.25], sampleRate: 16_000))

  #expect(try await session.finish().text == "4 samples")
  #expect(fake.requests.map(\.model) == ["m"])
  #expect(fake.sessions.first?.isFinished == true)
  #expect(fake.sessions.first?.isCancelled == false)

  let refusing = FakeLiveTranscriber(openFailure: .rateLimited) { _ in Transcript(text: "") }
  await #expect(throws: WisperError.rateLimited) {
    _ = try await refusing.open(LiveTranscriptionRequest(model: "m"))
  }
  #expect(refusing.sessions.isEmpty)
}
