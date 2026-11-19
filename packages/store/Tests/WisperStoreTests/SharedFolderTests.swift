import Foundation
import Testing
import WisperDomain

@testable import WisperStore

/// The two ways a library can watch its folder. Both must notice the same things.
enum Watching: String, CaseIterable, CustomTestStringConvertible {
  /// File system events on macOS.
  case events
  /// What runs where there are no file system events, such as iOS.
  case polling

  var testDescription: String { rawValue }

  var mode: WatchMode {
    switch self {
    case .events: .automatic
    case .polling: .polling(interval: 0.15)
    }
  }
}

/// Several libraries on one folder stand in for several processes: each has its own lock
/// handle and its own memory, so they only meet on disk, as the app and the `wisper` tool do.
@Suite("FileLibrary sharing its folder")
struct SharedFolderTests {
  let folder = TemporaryFolder()

  @Test(arguments: Watching.allCases)
  func twoLibrariesSeeEachOthersWrites(_ watching: Watching) async throws {
    let app = FileLibrary(root: folder.url, watching: watching.mode)
    let tool = FileLibrary(root: folder.url, watching: watching.mode)
    // The app has read everything once, the way it does at launch.
    #expect(try await app.settings() == Settings())
    #expect(try await app.meetings().isEmpty)
    let heard = ChangeRecorder(app.changes())

    let word = DictionaryWord(text: "Kubernetes")
    let snippet = Snippet(trigger: "intro", expansion: "Hi!")
    let dictation = Dictation(rawText: "hello", text: "Hello.", duration: 1)
    let meeting = SampleData.meetings()[0]
    try await tool.updateSettings { $0.userName = "Alex" }
    try await tool.save(word)
    try await tool.save(snippet)
    try await tool.save(dictation)
    try await tool.save(meeting)

    for change in LibraryChange.allCases {
      #expect(await heard.saw(change), "\(change) from the other library was not reported")
    }
    #expect(try await app.settings().userName == "Alex")
    #expect(try await app.words().map(\.id) == [word.id])
    #expect(try await app.snippets().map(\.id) == [snippet.id])
    #expect(try await app.dictations().map(\.id) == [dictation.id])
    #expect(try await app.meetings().map(\.id) == [meeting.id])

    // An edit and a delete are noticed as well.
    var edited = meeting
    edited.userNotes = "Added by the tool."
    try await tool.save(edited)
    #expect(await heard.saw(.meetings, times: 2))
    #expect(try await app.meeting(meeting.id)?.userNotes == "Added by the tool.")
    try await tool.deleteMeeting(meeting.id)
    #expect(await heard.saw(.meetings, times: 3))
    #expect(try await app.meetings().isEmpty)
    try await tool.deleteWord(word.id)
    #expect(await heard.saw(.words, times: 2))
    #expect(try await app.words().isEmpty)
  }

  @Test(arguments: Watching.allCases)
  func aPlainWriteFromOutsideIsNoticed(_ watching: Watching) async throws {
    let library = FileLibrary(root: folder.url, watching: watching.mode)
    try await library.save(DictionaryWord(text: "Kubernetes", createdAt: ago(100)))
    #expect(try await library.words().count == 1)
    let heard = ChangeRecorder(library.changes())
    #expect(await heard.stayedQuiet(for: 0.4))

    // No lock, no rename: just bytes written over the file.
    let created = Timestamp.string(from: ago(10))
    try folder.writeFromOutside(
      """
      [{"id":"\(UUID().uuidString)","text":"PostgreSQL","createdAt":"\(created)"},
       {"id":"\(UUID().uuidString)","text":"Priya Raman","createdAt":"\(Timestamp.string(from: ago(50)))"}]
      """,
      to: "dictionary.json"
    )
    #expect(await heard.saw(.words))
    #expect(try await library.words().map(\.text) == ["PostgreSQL", "Priya Raman"])

    // A meeting made by hand shows up, and gets its Markdown copy.
    let id = UUID()
    try folder.writeFromOutside(
      """
      {"id":"\(id.uuidString)","title":"Written by a script","startedAt":"\(created)","userNotes":"hello"}
      """,
      to: "meetings/\(id.uuidString)/meeting.json"
    )
    #expect(await heard.saw(.meetings))
    let meeting = try #require(try await library.meeting(id))
    #expect(meeting.title == "Written by a script")
    #expect(try await library.meetings() == [meeting])
    let notes = try String(contentsOf: folder.file("meetings/\(id.uuidString)/notes.md"), encoding: .utf8)
    #expect(notes == meeting.markdown())

    // Edited in place, by hand.
    try folder.writeFromOutside(
      """
      {"id":"\(id.uuidString)","title":"Edited by hand","startedAt":"\(created)"}
      """,
      to: "meetings/\(id.uuidString)/meeting.json"
    )
    #expect(await heard.saw(.meetings, times: 2))
    #expect(try await library.meetings().map(\.title) == ["Edited by hand"])

    try FileManager.default.removeItem(at: folder.file("meetings/\(id.uuidString)"))
    #expect(await heard.saw(.meetings, times: 3))
    #expect(try await library.meetings().isEmpty)
    #expect(heard.count(of: .settings) == 0 && heard.count(of: .dictations) == 0)
  }

  @Test(arguments: Watching.allCases)
  func aWriteRightAfterListeningStartsIsNotMissed(_ watching: Watching) async throws {
    let library = FileLibrary(root: folder.url, watching: watching.mode)
    try await library.save(Snippet(trigger: "one", expansion: "1"))
    let stream = library.changes()
    // Nothing has had a chance to start watching yet.
    try folder.writeFromOutside("[]", to: "snippets.json")
    let id = UUID()
    try folder.writeFromOutside(
      "{\"id\":\"\(id.uuidString)\",\"title\":\"Quick\",\"startedAt\":\"2026-11-13T09:30:00Z\"}",
      to: "meetings/\(id.uuidString)/meeting.json"
    )
    let heard = ChangeRecorder(stream)
    #expect(await heard.saw(.snippets))
    #expect(await heard.saw(.meetings))
  }

  @Test(arguments: Watching.allCases)
  func aLibrarysOwnWriteIsReportedOnce(_ watching: Watching) async throws {
    let library = FileLibrary(root: folder.url, watching: watching.mode)
    let heard = ChangeRecorder(library.changes())
    #expect(await heard.stayedQuiet(for: 0.3))

    let meeting = Meeting(title: "Standup")
    try await library.save(DictionaryWord(text: "Kubernetes"))
    try await library.save(meeting)
    // Audio being recorded is not a change to the library.
    let audio = try await library.audioDirectory(forMeeting: meeting.id)
    try Data("sound".utf8).write(to: audio.appendingPathComponent("microphone-0.m4a"))
    let dictationAudio = try await library.dictationAudioDirectory()
    try Data("sound".utf8).write(to: dictationAudio.appendingPathComponent("a.m4a"))

    #expect(await heard.saw(.words))
    #expect(await heard.saw(.meetings))
    // Long enough for the watcher to have had its say about the same writes.
    try await Task.sleep(for: .milliseconds(700))
    #expect(heard.all.sorted { "\($0)" < "\($1)" } == [.meetings, .words])
  }

  @Test func writersOnTheSameFolderNeverLoseAnUpdate() async throws {
    let writers = 4
    let rounds = 40
    try await withThrowingTaskGroup(of: Void.self) { group in
      for writer in 0..<writers {
        let library = FileLibrary(root: folder.url)
        group.addTask {
          for round in 0..<rounds {
            try await library.save(DictionaryWord(text: "word \(writer)-\(round)"))
            try await library.save(Dictation(rawText: "r", text: "dictation \(writer)-\(round)", duration: 1))
            // Each writer owns one setting. Losing an update would wipe somebody else's.
            try await library.updateSettings { settings in
              switch writer {
              case 0: settings.userName = "round \(round)"
              case 1: settings.language = "l\(round)"
              case 2: settings.microphoneID = "mic \(round)"
              default: settings.apiBaseURL = "http://localhost/\(round)"
              }
            }
            if round % 10 == 0 { try await library.save(Meeting(title: "meeting \(writer)-\(round)")) }
          }
        }
      }
      try await group.waitForAll()
    }

    let fresh = FileLibrary(root: folder.url)
    let words = try await fresh.words()
    #expect(words.count == writers * rounds)
    #expect(Set(words.map(\.text)).count == writers * rounds)
    #expect(try await fresh.dictations().count == writers * rounds)
    #expect(try await fresh.meetings().count == writers * (rounds / 10))
    let settings = try await fresh.settings()
    #expect(settings.userName == "round \(rounds - 1)")
    #expect(settings.language == "l\(rounds - 1)")
    #expect(settings.microphoneID == "mic \(rounds - 1)")
    #expect(settings.apiBaseURL == "http://localhost/\(rounds - 1)")
    #expect(folder.names().allSatisfy { !$0.contains(".corrupt-") && !$0.hasPrefix(".tmp-") })
  }

  @Test func oneLibraryIsSafeToUseFromManyTasksAtOnce() async throws {
    let library = FileLibrary(root: folder.url)
    let count = 60
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<count {
        group.addTask {
          try await library.save(Snippet(trigger: "t\(index)", expansion: "e"))
          _ = try await library.snippets()
          try await library.save(Meeting(title: "m\(index)"))
          _ = try await library.meetings(search: "m")
        }
      }
      try await group.waitForAll()
    }
    #expect(try await library.snippets().count == count)
    #expect(try await library.meetings().count == count)
  }

  @Test func retentionUsesASettingChangedByAnotherLibrary() async throws {
    let app = FileLibrary(root: folder.url)
    let tool = FileLibrary(root: folder.url)
    try await app.save(Dictation(createdAt: ago(3 * 86_400), rawText: "a", text: "old", duration: 1))
    #expect(try await app.settings().historyRetention == .forever)
    try await tool.updateSettings { $0.historyRetention = .day }
    try await app.save(Dictation(rawText: "b", text: "new", duration: 1))
    #expect(try await tool.dictations().map(\.text) == ["new"])
  }

  @Test func everyListenerGetsItsOwnStreamAndStreamsEndWithTheLibrary() async throws {
    var library: FileLibrary? = FileLibrary(root: folder.url)
    let first = try #require(library).changes()
    let second = try #require(library).changes()
    try await library?.save(Snippet(trigger: "a", expansion: "b"))

    var firstIterator = first.makeAsyncIterator()
    var secondIterator = second.makeAsyncIterator()
    #expect(await firstIterator.next() == .snippets)
    #expect(await secondIterator.next() == .snippets)

    library = nil
    #expect(await firstIterator.next() == nil)
    #expect(await secondIterator.next() == nil)
  }

  @Test(arguments: Watching.allCases)
  func theFolderCanBeDeletedAndUsedAgain(_ watching: Watching) async throws {
    let library = FileLibrary(root: folder.url, watching: watching.mode)
    try await library.save(DictionaryWord(text: "Kubernetes"))
    try await library.save(Meeting(title: "Standup"))
    let heard = ChangeRecorder(library.changes())
    #expect(await heard.stayedQuiet(for: 0.3))
    try FileManager.default.removeItem(at: folder.url)

    // Everything going away is a change too.
    #expect(await heard.saw(.words))
    #expect(await heard.saw(.meetings))
    #expect(try await library.words().isEmpty)
    #expect(try await library.meetings().isEmpty)
    try await library.save(DictionaryWord(text: "PostgreSQL"))
    #expect(folder.exists(".lock"))

    // The lock and the watch are on the new folder: another library is kept in step.
    let other = FileLibrary(root: folder.url)
    #expect(try await other.words().map(\.text) == ["PostgreSQL"])
    try await other.save(Snippet(trigger: "intro", expansion: "Hi!"))
    #expect(await heard.saw(.snippets))
    #expect(try await library.snippets().count == 1)
  }
}
