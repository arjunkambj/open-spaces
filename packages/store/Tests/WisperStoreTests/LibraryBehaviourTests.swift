import Foundation
import Testing
import WisperDomain

@testable import WisperStore

/// What every `Library` must do. The same checks run against the in-memory fake and the
/// file adapter, which is what shows that the two agree.
@Suite("Library behaviour")
struct LibraryBehaviourTests {
  @Test(arguments: Adapter.allCases)
  func settingsStartAsDefaultsAndKeepChanges(_ adapter: Adapter) async throws {
    let (library, folder) = adapter.make()
    defer { _ = folder }
    #expect(try await library.settings() == Settings())

    let onboarded = ago(60)
    let returned = try await library.updateSettings { settings in
      settings.userName = "Alex"
      settings.onboardedAt = onboarded
      settings.language = "en"
      settings.historyRetention = .week
      settings.styles[.email] = .veryCasual
      settings.shortcuts[.pushToTalk] = KeyCombo(keyCode: KeyCombo.KeyCode.space, modifiers: [.option])
      settings.meetings.keepAudio = false
    }
    #expect(returned.userName == "Alex")
    #expect(returned.onboardedAt == onboarded)
    #expect(returned.style(for: .email) == .veryCasual)
    #expect(returned.shortcut(for: .pushToTalk)?.modifiers == [.option])
    #expect(!returned.meetings.keepAudio)
    #expect(try await library.settings() == returned)

    // A second change builds on the first.
    let again = try await library.updateSettings { $0.playSounds = false }
    #expect(again.userName == "Alex")
    #expect(!again.playSounds)
  }

  @Test(arguments: Adapter.allCases)
  func wordsAreNewestFirstAndReplacedByID(_ adapter: Adapter) async throws {
    let (library, folder) = adapter.make()
    defer { _ = folder }
    #expect(try await library.words().isEmpty)

    let old = DictionaryWord(text: "Kubernetes", replaces: "cooper netties", createdAt: ago(300))
    let new = DictionaryWord(text: "PostgreSQL", createdAt: ago(100))
    let middle = DictionaryWord(text: "Priya Raman", createdAt: ago(200))
    for word in [old, new, middle] { try await library.save(word) }
    #expect(try await library.words() == [new, middle, old])

    var edited = old
    edited.text = "kubectl"
    edited.replaces = nil
    try await library.save(edited)
    #expect(try await library.words() == [new, middle, edited])

    try await library.deleteWord(middle.id)
    try await library.deleteWord(UUID())
    #expect(try await library.words() == [new, edited])
  }

  @Test(arguments: Adapter.allCases)
  func snippetsAreNewestFirstAndReplacedByID(_ adapter: Adapter) async throws {
    let (library, folder) = adapter.make()
    defer { _ = folder }
    #expect(try await library.snippets().isEmpty)

    let old = Snippet(
      trigger: "my calendar link",
      expansion: "https://cal.example.com/alex",
      createdAt: ago(300)
    )
    let new = Snippet(trigger: "sign off", expansion: "Thanks,\nAlex \u{1F44B}", createdAt: ago(100))
    try await library.save(old)
    try await library.save(new)
    #expect(try await library.snippets() == [new, old])

    var edited = old
    edited.expansion = "https://cal.example.com/alex/30"
    try await library.save(edited)
    #expect(try await library.snippets() == [new, edited])

    try await library.deleteSnippet(new.id)
    #expect(try await library.snippets() == [edited])
  }

  @Test(arguments: Adapter.allCases)
  func dictationsAreNewestFirstSearchableAndLimited(_ adapter: Adapter) async throws {
    let (library, folder) = adapter.make()
    defer { _ = folder }
    #expect(try await library.dictations().isEmpty)

    let lunch = Dictation(
      createdAt: ago(300),
      rawText: "um are you free for lunch",
      text: "Are you free for Lunch?",
      duration: 3.5,
      appName: "Messages",
      bundleID: "com.apple.MobileSMS"
    )
    let review = Dictation(
      createdAt: ago(200),
      mode: .command,
      rawText: "make this shorter",
      text: "Could we move the review to Thursday?",
      duration: 6
    )
    let failed = Dictation(
      createdAt: ago(100),
      rawText: "",
      text: "",
      duration: 2,
      audioFile: "kept.m4a",
      failure: "Could not reach OpenAI."
    )
    for dictation in [review, lunch, failed] { try await library.save(dictation) }

    #expect(try await library.dictations() == [failed, review, lunch])
    #expect(try await library.dictations(search: "LUNCH", limit: nil) == [lunch])
    // Search looks at the final text only, not at what was first heard.
    #expect(try await library.dictations(search: "shorter", limit: nil).isEmpty)
    #expect(try await library.dictations(search: "", limit: nil).count == 3)
    #expect(try await library.dictations(search: nil, limit: 2) == [failed, review])
    #expect(try await library.dictations(search: "e", limit: 1) == [review])
    #expect(try await library.dictations(search: nil, limit: 0).isEmpty)

    var retried = failed
    retried.text = "Now it worked."
    retried.failure = nil
    try await library.save(retried)
    #expect(try await library.dictations() == [retried, review, lunch])

    try await library.deleteDictations([lunch.id, UUID()])
    #expect(try await library.dictations() == [retried, review])
    try await library.deleteAllDictations()
    #expect(try await library.dictations().isEmpty)
  }

  @Test(arguments: Adapter.allCases)
  func savingADictationAppliesTheRetentionSetting(_ adapter: Adapter) async throws {
    let (library, folder) = adapter.make()
    defer { _ = folder }
    let ancient = Dictation(createdAt: ago(40 * 86_400), rawText: "a", text: "ancient", duration: 1)
    let lastWeek = Dictation(createdAt: ago(5 * 86_400), rawText: "b", text: "last week", duration: 1)
    let today = Dictation(createdAt: ago(3_600), rawText: "c", text: "today", duration: 1)
    for dictation in [ancient, lastWeek, today] { try await library.save(dictation) }
    #expect(try await library.dictations().count == 3)

    // The setting alone removes nothing. The next save does.
    try await library.updateSettings { $0.historyRetention = .month }
    #expect(try await library.dictations().count == 3)
    try await library.save(today)
    #expect(try await library.dictations() == [today, lastWeek])

    try await library.updateSettings { $0.historyRetention = .day }
    let fresh = Dictation(createdAt: ago(1), rawText: "d", text: "fresh", duration: 1)
    try await library.save(fresh)
    #expect(try await library.dictations() == [fresh, today])

    try await library.updateSettings { $0.historyRetention = .never }
    try await library.save(Dictation(rawText: "e", text: "gone at once", duration: 1))
    #expect(try await library.dictations().isEmpty)
  }

  @Test(arguments: Adapter.allCases)
  func meetingsAreNewestFirstAndReplacedByID(_ adapter: Adapter) async throws {
    let (library, folder) = adapter.make()
    defer { _ = folder }
    #expect(try await library.meetings().isEmpty)
    #expect(try await library.meeting(UUID()) == nil)

    let samples = SampleData.meetings(now: ago(0))
    for meeting in samples.reversed() { try await library.save(meeting) }
    #expect(try await library.meetings() == samples)
    #expect(try await library.meeting(samples[1].id) == samples[1])

    var edited = samples[2]
    edited.title = "1:1 with Jordan (moved)"
    edited.status = .failed
    edited.failure = "The recording was empty."
    edited.userNotes = "Line one\n\n- a list\n- with \"quotes\" and a / slash"
    edited.segments.append(TranscriptSegment(speaker: .named("Jordan"), start: 7, end: 9.25, text: "Fine!"))
    try await library.save(edited)
    #expect(try await library.meetings() == [samples[0], samples[1], edited])
    #expect(try await library.meeting(edited.id) == edited)

    try await library.deleteMeeting(samples[0].id)
    try await library.deleteMeeting(UUID())
    #expect(try await library.meetings() == [samples[1], edited])
    #expect(try await library.meeting(samples[0].id) == nil)
  }

  @Test(arguments: Adapter.allCases)
  func meetingSearchLooksAtTitleNotesTagsAndTranscript(_ adapter: Adapter) async throws {
    let (library, folder) = adapter.make()
    defer { _ = folder }
    let samples = SampleData.meetings(now: ago(0))
    for meeting in samples { try await library.save(meeting) }
    let sync = samples[0]
    let customer = samples[1]
    let oneToOne = samples[2]

    func found(_ search: String?) async throws -> [Meeting] { try await library.meetings(search: search) }
    #expect(try await found(nil) == samples)
    #expect(try await found("") == samples)
    #expect(try await found("NORTHWIND") == [customer])  // title, any case
    #expect(try await found("pricing page") == [sync])  // the user's own notes
    #expect(try await found("field team") == [customer])  // summary
    #expect(try await found("product") == [sync])  // tag (and title)
    #expect(try await found("how is the week") == [oneToOne])  // transcript
    #expect(try await found("main risk") == [sync])  // key point
    #expect(try await found("keep the launch date") == [sync])  // decision
    #expect(try await found("summary and pricing") == [customer])  // action item
    #expect(try await found("pricing") == [sync, customer])  // newest first
    #expect(try await found("no such words anywhere").isEmpty)
    // The owner of an action item and the speaker's label are not searched.
    #expect(try await found("Jordan") == [oneToOne])
    #expect(try await found("Others").isEmpty)
  }

  @Test(arguments: Adapter.allCases)
  func audioFoldersExistAndAreSeparate(_ adapter: Adapter) async throws {
    let (library, folder) = adapter.make()
    defer { _ = folder }
    let first = UUID()
    let second = UUID()
    let dictationAudio = try await library.dictationAudioDirectory()
    let firstAudio = try await library.audioDirectory(forMeeting: first)
    let secondAudio = try await library.audioDirectory(forMeeting: second)

    var isFolder: ObjCBool = false
    for url in [dictationAudio, firstAudio, secondAudio] {
      #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue)
    }
    #expect(Set([dictationAudio, firstAudio, secondAudio].map(\.path)).count == 3)
    #expect(try await library.audioDirectory(forMeeting: first) == firstAudio)
    // Asking for a folder does not make a meeting.
    #expect(try await library.meetings().isEmpty)
    try? FileManager.default.removeItem(at: dictationAudio.deletingLastPathComponent())
  }

  @Test(arguments: Adapter.allCases)
  func everyWriteIsReportedToEveryListener(_ adapter: Adapter) async throws {
    let (library, folder) = adapter.make()
    defer { _ = folder }
    let first = ChangeRecorder(library.changes())
    let second = ChangeRecorder(library.changes())

    let word = DictionaryWord(text: "Open Wisper")
    let snippet = Snippet(trigger: "intro", expansion: "Hi!")
    let dictation = Dictation(rawText: "hello", text: "Hello.", duration: 1)
    let meeting = Meeting(title: "Standup")
    try await library.updateSettings { $0.userName = "Alex" }
    try await library.save(word)
    try await library.save(snippet)
    try await library.save(dictation)
    try await library.save(meeting)

    for recorder in [first, second] {
      for change in LibraryChange.allCases {
        #expect(await recorder.saw(change), "\(change) was not reported")
      }
    }

    try await library.deleteWord(word.id)
    try await library.deleteSnippet(snippet.id)
    try await library.deleteDictations([dictation.id])
    try await library.deleteMeeting(meeting.id)
    for change in [LibraryChange.words, .snippets, .dictations, .meetings] {
      #expect(await first.saw(change, times: 2), "deleting did not report \(change)")
    }
    try await library.deleteAllDictations()
    #expect(await first.saw(.dictations, times: 3))
  }
}
