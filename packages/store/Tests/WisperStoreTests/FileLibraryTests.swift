import Foundation
import Testing
import WisperDomain

@testable import WisperStore

/// What only the file adapter promises: the layout on disk, safe writes, getting past a
/// damaged file, cleaning up audio, and sharing the folder with other processes.
@Suite("FileLibrary on disk")
struct FileLibraryTests {
  let folder = TemporaryFolder()

  private func text(_ path: String) throws -> String {
    try String(contentsOf: folder.file(path), encoding: .utf8)
  }

  private func json(_ path: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(contentsOf: folder.file(path)))
  }

  // MARK: Layout

  @Test func nothingIsCreatedUntilSomethingIsSaved() async throws {
    let library = FileLibrary(root: folder.url)
    #expect(try await library.settings() == Settings())
    #expect(try await library.words().isEmpty)
    #expect(try await library.snippets().isEmpty)
    #expect(try await library.dictations().isEmpty)
    #expect(try await library.meetings().isEmpty)
    #expect(try await library.meeting(UUID()) == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.url.path))
  }

  @Test func theLayoutOnDiskIsTheDocumentedOne() async throws {
    let library = FileLibrary(root: folder.url)
    let meeting = SampleData.meetings()[0]
    try await library.updateSettings { $0.userName = "Alex" }
    try await library.save(DictionaryWord(text: "Kubernetes"))
    try await library.save(Snippet(trigger: "intro", expansion: "Hi!"))
    try await library.save(Dictation(rawText: "hello", text: "Hello.", duration: 1))
    try await library.save(meeting)
    let audio = try await library.audioDirectory(forMeeting: meeting.id)
    let dictationAudio = try await library.dictationAudioDirectory()

    #expect(
      folder.names() == [
        ".lock", "dictation-audio", "dictations.json", "dictionary.json", "meetings", "settings.json",
        "snippets.json",
      ]
    )
    #expect(folder.names(in: "meetings") == [meeting.id.uuidString])
    #expect(folder.names(in: "meetings/\(meeting.id.uuidString)") == ["audio", "meeting.json", "notes.md"])
    #expect(audio.path == folder.file("meetings/\(meeting.id.uuidString)/audio").path)
    #expect(dictationAudio.path == folder.file("dictation-audio").path)
    #expect(try text("meetings/\(meeting.id.uuidString)/notes.md") == meeting.markdown())
  }

  @Test func jsonIsPrettySortedAndUsesISODates() async throws {
    let library = FileLibrary(root: folder.url)
    let created = Date(timeIntervalSince1970: 1_794_562_200)  // 2026-11-13T09:30:00Z
    try await library.save(
      DictionaryWord(
        id: UUID(uuidString: "0A4C9D5E-3B1F-4E7A-9C2D-6F8B1A2C3D4E")!,
        text: "Kubernetes",
        replaces: "cooper netties",
        createdAt: created
      )
    )
    #expect(
      try text("dictionary.json") == """
        [
          {
            "createdAt" : "2026-11-13T09:30:00Z",
            "id" : "0A4C9D5E-3B1F-4E7A-9C2D-6F8B1A2C3D4E",
            "replaces" : "cooper netties",
            "text" : "Kubernetes"
          }
        ]

        """
    )

    try await library.updateSettings { $0.apiBaseURL = "http://localhost:8080/v1" }
    let settings = try text("settings.json")
    #expect(settings.contains("\"apiBaseURL\" : \"http://localhost:8080/v1\""))
    let keys = settings.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map(String.init)
    #expect(keys == keys.sorted())
  }

  @Test func notesFileIsRewrittenOnEverySave() async throws {
    let library = FileLibrary(root: folder.url)
    var meeting = Meeting(title: "Planning", startedAt: ago(600), status: .ready)
    try await library.save(meeting)
    let path = "meetings/\(meeting.id.uuidString)/notes.md"
    #expect(try text(path).hasPrefix("# Planning\n"))

    meeting.title = "Planning, part two"
    meeting.notes = MeetingNotes(summary: "We agreed on the plan.", decisions: ["Ship on Friday"])
    try await library.save(meeting)
    let notes = try text(path)
    #expect(notes == meeting.markdown())
    #expect(notes.contains("## Decisions") && notes.contains("- Ship on Friday"))
  }

  // MARK: Dates

  @Test func datesSurviveSavingExactly() async throws {
    let library = FileLibrary(root: folder.url)
    let awkward = [
      Date(),
      Date(timeIntervalSinceReferenceDate: 784_111_111.123_456_7),
      Date(timeIntervalSince1970: 0.5),
      Date(timeIntervalSince1970: -86_400.25),
      Date(timeIntervalSince1970: 1_709_164_799.999),  // one millisecond before 29 February ends
      Date(timeIntervalSince1970: 4_102_444_800),  // 2100, not a leap year
    ]
    for (index, date) in awkward.enumerated() {
      try await library.save(DictionaryWord(text: "word \(index)", createdAt: date))
    }
    // A second library has nothing in memory, so this is what the file really holds.
    let reread = try await FileLibrary(root: folder.url).words()
    #expect(Set(reread.map(\.createdAt)) == Set(awkward))
  }

  @Test func datesAreWrittenShortAndReadInManyShapes() throws {
    #expect(Timestamp.string(from: Date(timeIntervalSince1970: 1_794_562_200)) == "2026-11-13T09:30:00Z")
    #expect(
      Timestamp.string(from: Date(timeIntervalSince1970: 1_794_562_200.25)) == "2026-11-13T09:30:00.250Z"
    )
    #expect(Timestamp.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    #expect(Timestamp.string(from: Date(timeIntervalSince1970: 951_782_400)) == "2000-02-29T00:00:00Z")
    #expect(Timestamp.string(from: Date(timeIntervalSince1970: -1)) == "1969-12-31T23:59:59Z")

    let expected = Date(timeIntervalSince1970: 1_794_562_200)
    let shapes = [
      "2026-11-13T09:30:00Z", "2026-11-13T09:30:00.000Z", "2026-11-13T09:30:00.000000Z",
      "2026-11-13T09:30:00+00:00", "2026-11-13T15:00:00+05:30", "2026-11-13T01:30:00-0800",
      "2026-11-13 09:30:00Z", "2026-11-13T09:30Z", "2026-11-13T09:30:00",
    ]
    for shape in shapes { #expect(Timestamp.date(from: shape) == expected, "\(shape)") }
    #expect(Timestamp.date(from: "2026-11-13T09:30:00.5Z") == expected.addingTimeInterval(0.5))
    #expect(Timestamp.date(from: "2026-11-13T09:30:00.123456789123Z") != nil)
    #expect(Timestamp.date(from: "2026-11-13") == Date(timeIntervalSince1970: 1_794_528_000))

    // The system's own formatter agrees, with and without a fraction.
    let system = ISO8601DateFormatter()
    #expect(system.date(from: Timestamp.string(from: expected)) == expected)
    system.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fractional = expected.addingTimeInterval(0.125)
    #expect(system.date(from: Timestamp.string(from: fractional)) == fractional)

    for nonsense in [
      "", "yesterday", "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z", "2026-11-13T25:00:00Z",
      "2026-11-13T09:30:00Zjunk", "2026-11-13T09:30:00.Z", "20261113",
    ] {
      #expect(Timestamp.date(from: nonsense) == nil, "\(nonsense)")
    }
  }

  @Test func filesWrittenByOtherToolsWithFractionalDatesLoad() async throws {
    try folder.writeFromOutside(
      """
      [{"id":"0A4C9D5E-3B1F-4E7A-9C2D-6F8B1A2C3D4E","text":"Kubernetes","createdAt":"2026-11-13T09:30:00.250+01:00"}]
      """,
      to: "dictionary.json"
    )
    let words = try await FileLibrary(root: folder.url).words()
    #expect(words.map(\.text) == ["Kubernetes"])
    #expect(words.first?.createdAt == Date(timeIntervalSince1970: 1_794_558_600.25))
  }

  // MARK: Safe writes and damaged files

  @Test func writesLeaveNoTemporaryFilesBehind() async throws {
    let library = FileLibrary(root: folder.url)
    for index in 0..<20 {
      try await library.save(Snippet(trigger: "t\(index)", expansion: "e\(index)"))
      try await library.save(Meeting(title: "Meeting \(index)"))
    }
    #expect(folder.names().allSatisfy { !$0.hasPrefix(".tmp-") })
    for name in folder.names(in: "meetings") {
      #expect(folder.names(in: "meetings/\(name)") == ["meeting.json", "notes.md"])
    }
  }

  @Test func aReaderNeverSeesAHalfWrittenFile() async throws {
    let library = FileLibrary(root: folder.url)
    try await library.save(Snippet(trigger: "first", expansion: "x"))
    let file = folder.file("snippets.json")
    let reader = Task.detached {
      var reads = 0
      while !Task.isCancelled {
        let data = try Data(contentsOf: file)
        _ = try LibraryJSON.decode([Snippet].self, from: data)
        reads += 1
      }
      return reads
    }
    let filler = String(repeating: "long text ", count: 400)
    for index in 0..<150 {
      try await library.save(Snippet(trigger: "t\(index)", expansion: filler))
    }
    reader.cancel()
    #expect(try await reader.value > 0)
    #expect(try await library.snippets().count == 151)
  }

  @Test func aStaleTemporaryFileFromACrashIsCleanedUp() async throws {
    try folder.writeFromOutside("half a fi", to: ".tmp-settings.json-OLD")
    try folder.writeFromOutside("half a fi", to: ".tmp-settings.json-NEW")
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7_200)],
      ofItemAtPath: folder.file(".tmp-settings.json-OLD").path
    )
    try await FileLibrary(root: folder.url).updateSettings { $0.userName = "Alex" }
    // The new one may belong to a write that is still going on, so it stays.
    #expect(!folder.exists(".tmp-settings.json-OLD"))
    #expect(folder.exists(".tmp-settings.json-NEW"))
  }

  @Test(arguments: ["{ \"userName\": \"Al", "not json at all", "[1, 2, 3]", "\u{0}\u{1}\u{2}"])
  func aCorruptSettingsFileIsMovedAsideAndDefaultsAreUsed(_ damage: String) async throws {
    try folder.writeFromOutside(damage, to: "settings.json")
    let library = FileLibrary(root: folder.url)
    #expect(try await library.settings() == Settings())

    let aside = folder.names().filter { $0.hasPrefix("settings.json.corrupt-") }
    #expect(aside.count == 1)
    #expect(try text(aside[0]) == damage)
    #expect(!folder.exists("settings.json"))

    // The app carries on: the next change is saved as usual.
    try await library.updateSettings { $0.userName = "Alex" }
    #expect(try await FileLibrary(root: folder.url).settings().userName == "Alex")
  }

  @Test func settingsWithOneBadValueKeepTheRest() async throws {
    try folder.writeFromOutside(
      """
      {"userName": "Alex", "showPill": "sometimes", "playSounds": false, "someFutureKey": 1}
      """,
      to: "settings.json"
    )
    let settings = try await FileLibrary(root: folder.url).settings()
    #expect(settings.userName == "Alex")
    #expect(!settings.playSounds)
    #expect(settings.showPill)
    #expect(folder.names().contains { $0.hasPrefix("settings.json.corrupt-") })
    #expect(try text("settings.json").contains("\"userName\" : \"Alex\""))
  }

  // MARK: Files written by a newer version

  @Test func settingsWithAChoiceThisVersionDoesNotKnowAreLeftAsTheyAre() async throws {
    let written = """
      {"userName": "Alex", "historyRetention": "a fortnight", "playSounds": false,
       "styles": {"email": "poetic"}, "apiBaseURL": "http://localhost:11434/v1"}
      """
    try folder.writeFromOutside(written, to: "settings.json")
    let settings = try await FileLibrary(root: folder.url).settings()
    #expect(settings.userName == "Alex")
    #expect(!settings.playSounds)
    #expect(settings.historyRetention == .forever)
    #expect(settings.apiBaseURL == "http://localhost:11434/v1")
    // Nothing is moved aside and nothing is rewritten.
    #expect(folder.names() == ["settings.json"])
    #expect(try text("settings.json") == written)
  }

  @Test func aMeetingWithAStatusThisVersionDoesNotKnowIsLeftAsItIs() async throws {
    let library = FileLibrary(root: folder.url)
    let meeting = Meeting(
      title: "Future",
      startedAt: ago(100),
      status: .ready,
      segments: [TranscriptSegment(speaker: .me, start: 1, end: 2, text: "Still here.")],
      userNotes: "keep me"
    )
    try await library.save(meeting)
    let path = "meetings/\(meeting.id.uuidString)/meeting.json"
    let written = try text(path).replacingOccurrences(of: "\"ready\"", with: "\"paused\"")
    #expect(written.contains("\"paused\""))
    try folder.writeFromOutside(written, to: path)

    // A fresh library, as after a restart, and the one that was already running.
    for reader in [FileLibrary(root: folder.url), library] {
      let read = try #require(try await reader.meeting(meeting.id))
      #expect(read.status == .ready)
      #expect(read.userNotes == "keep me")
      #expect(read.segments == meeting.segments)
      #expect(try await reader.meetings().map(\.id) == [meeting.id])
    }
    // The file is not moved aside and not rewritten: the newer version finds its status again.
    #expect(folder.names(in: "meetings/\(meeting.id.uuidString)") == ["meeting.json", "notes.md"])
    #expect(try text(path) == written)
  }

  @Test func aDictationWithAModeThisVersionDoesNotKnowStaysInTheHistory() async throws {
    let id = UUID()
    let written = """
      [{"id": "\(id.uuidString)", "createdAt": "\(Timestamp.string(from: ago(60)))", "mode": "translate",
        "rawText": "hola", "text": "hello", "duration": 2}]
      """
    try folder.writeFromOutside(written, to: "dictations.json")
    let history = try await FileLibrary(root: folder.url).dictations()
    #expect(history.map(\.id) == [id])
    #expect(history.first?.text == "hello")
    #expect(folder.names() == ["dictations.json"])
    #expect(try text("dictations.json") == written)
  }

  // MARK: The folder is private

  @Test func anExistingDataFolderIsClosedToOtherUsersWhenItIsOpened() async throws {
    func mode(_ path: String = "") throws -> Int {
      let attributes = try FileManager.default.attributesOfItem(atPath: folder.file(path).path)
      return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    // A folder made by something else, open to everybody.
    try FileManager.default.createDirectory(
      at: folder.file("dictation-audio"),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path)
    #expect(try mode() == 0o755)

    // Opening is enough: nothing has to be written first.
    let library = FileLibrary(root: folder.url)
    #expect(try mode() == 0o700)
    _ = try await library.dictationAudioDirectory()
    #expect(try mode("dictation-audio") == 0o700)

    // Opened up again while the app is not running: closed again at the next start.
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: folder.url.path)
    _ = FileLibrary(root: folder.url)
    #expect(try mode() == 0o700)

    // A folder the library makes itself is private from the start.
    let fresh = TemporaryFolder()
    try await FileLibrary(root: fresh.url).updateSettings { $0.userName = "Alex" }
    let made = try FileManager.default.attributesOfItem(atPath: fresh.url.path)[.posixPermissions]
    #expect((made as? NSNumber)?.intValue == 0o700)
  }

  @Test func settingsFromAnOlderVersionLoadWithDefaults() async throws {
    try folder.writeFromOutside("{\"userName\": \"Alex\"}", to: "settings.json")
    let settings = try await FileLibrary(root: folder.url).settings()
    #expect(settings.userName == "Alex")
    #expect(settings.transcriptionModel == Settings.defaultTranscriptionModel)
    // Nothing was wrong with the file, so it is left as it was.
    #expect(folder.names() == ["settings.json"])
  }

  @Test func anEmptyFileCountsAsMissing() async throws {
    try folder.writeFromOutside("", to: "settings.json")
    try folder.writeFromOutside("  \n", to: "dictations.json")
    let library = FileLibrary(root: folder.url)
    #expect(try await library.settings() == Settings())
    #expect(try await library.dictations().isEmpty)
    #expect(folder.names() == ["dictations.json", "settings.json"])
  }

  @Test func aListWithOneBadEntryKeepsTheGoodOnes() async throws {
    try folder.writeFromOutside(
      """
      [
        {"id":"0A4C9D5E-3B1F-4E7A-9C2D-6F8B1A2C3D4E","text":"Kubernetes","createdAt":"2026-11-13T09:30:00Z"},
        {"id":"not an id","text":"broken","createdAt":"2026-11-13T09:30:00Z"},
        "what is this",
        {"id":"1B5DAE6F-4C20-4F8B-AD3E-70C2B3D4E5F6","text":"PostgreSQL","createdAt":"2026-11-14T09:30:00Z"}
      ]
      """,
      to: "dictionary.json"
    )
    let library = FileLibrary(root: folder.url)
    #expect(try await library.words().map(\.text) == ["PostgreSQL", "Kubernetes"])
    #expect(folder.names().filter { $0.hasPrefix("dictionary.json.corrupt-") }.count == 1)
    // What was saved from the wreck is back on disk in the usual format.
    #expect(try await FileLibrary(root: folder.url).words().count == 2)
    #expect(folder.names().filter { $0.hasPrefix("dictionary.json.corrupt-") }.count == 1)
  }

  @Test func corruptFilesNeverOverwriteEachOther() async throws {
    let library = FileLibrary(root: folder.url)
    for round in 1...3 {
      try folder.writeFromOutside("damage number \(round)", to: "snippets.json")
      #expect(try await library.snippets().isEmpty)
    }
    let aside = folder.names().filter { $0.hasPrefix("snippets.json.corrupt-") }
    #expect(aside.count == 3)
    #expect(Set(try aside.map(text)) == ["damage number 1", "damage number 2", "damage number 3"])
  }

  @Test func oneCorruptMeetingDoesNotHideTheOthers() async throws {
    let library = FileLibrary(root: folder.url)
    let good = Meeting(title: "Good", startedAt: ago(100), status: .ready)
    let bad = Meeting(title: "Bad", startedAt: ago(50), status: .ready)
    try await library.save(good)
    try await library.save(bad)
    let audio = try await library.audioDirectory(forMeeting: bad.id)
    try Data("sound".utf8).write(to: audio.appendingPathComponent("microphone-0.m4a"))
    try folder.writeFromOutside("{ \"id\": ", to: "meetings/\(bad.id.uuidString)/meeting.json")

    #expect(try await library.meetings() == [good])
    #expect(try await library.meeting(bad.id) == nil)
    let left = folder.names(in: "meetings/\(bad.id.uuidString)")
    #expect(left.contains { $0.hasPrefix("meeting.json.corrupt-") })
    // The recording is not thrown away with the bad file.
    #expect(folder.exists("meetings/\(bad.id.uuidString)/audio/microphone-0.m4a"))
    // A fresh library agrees and does not trip over what was left.
    #expect(try await FileLibrary(root: folder.url).meetings() == [good])
  }

  @Test func aMeetingWithOneBadValueKeepsTheRest() async throws {
    let id = UUID()
    try folder.writeFromOutside(
      """
      {"id":"\(id.uuidString)","title":"Rescued","startedAt":"2026-11-13T09:30:00Z","status":"on fire",
       "userNotes":"still here","segments":"oops"}
      """,
      to: "meetings/\(id.uuidString)/meeting.json"
    )
    let meeting = try #require(try await FileLibrary(root: folder.url).meeting(id))
    #expect(meeting.title == "Rescued")
    #expect(meeting.userNotes == "still here")
    #expect(meeting.status == .ready)
    #expect(meeting.segments.isEmpty)
    #expect(folder.names(in: "meetings/\(id.uuidString)").contains { $0.hasPrefix("meeting.json.corrupt-") })
  }

  @Test func foldersThatAreNotMeetingsAreLeftAlone() async throws {
    let library = FileLibrary(root: folder.url)
    let meeting = Meeting(title: "Real", status: .ready)
    try await library.save(meeting)
    try folder.writeFromOutside("hello", to: "meetings/README.txt")
    try folder.writeFromOutside("{}", to: "meetings/not-a-meeting/meeting.json")
    try folder.writeFromOutside("x", to: "meetings/\(UUID().uuidString)/audio/chunk.m4a")
    #expect(try await library.meetings() == [meeting])
    #expect(folder.exists("meetings/README.txt") && folder.exists("meetings/not-a-meeting/meeting.json"))
  }

  @Test func theFolderNameDecidesAMeetingsID() async throws {
    let id = UUID()
    try folder.writeFromOutside(
      """
      {"id":"\(UUID().uuidString)","title":"Copied by hand","startedAt":"2026-11-13T09:30:00Z"}
      """,
      to: "meetings/\(id.uuidString.lowercased())/meeting.json"
    )
    let library = FileLibrary(root: folder.url)
    let meetings = try await library.meetings()
    #expect(meetings.map(\.id) == [id])
    #expect(try await library.meeting(id)?.title == "Copied by hand")
    try await library.deleteMeeting(id)
    #expect(folder.names(in: "meetings").isEmpty)
  }

  @Test func problemsAreReportedAsStorageErrors() async throws {
    // A file where the data folder should be.
    try Data("in the way".utf8).write(to: folder.url)
    let library = FileLibrary(root: folder.url)
    await #expect {
      try await library.save(DictionaryWord(text: "Kubernetes"))
    } throws: { error in
      guard case WisperError.storage(let detail) = error else { return false }
      return !detail.isEmpty
    }
    await #expect(throws: WisperError.self) { try await library.dictationAudioDirectory() }
    await #expect(throws: WisperError.self) { try await library.save(Meeting(title: "Nope")) }
  }

  // MARK: Audio clean-up

  private func keepAudio(_ library: FileLibrary, _ name: String) async throws {
    let audio = try await library.dictationAudioDirectory()
    try Data("sound".utf8).write(to: audio.appendingPathComponent(name))
  }

  @Test func retentionDeletesTheAudioOfDroppedEntries() async throws {
    let library = FileLibrary(root: folder.url)
    try await keepAudio(library, "old.m4a")
    try await keepAudio(library, "recent.m4a")
    let old = Dictation(
      createdAt: ago(3 * 86_400),
      rawText: "a",
      text: "old",
      duration: 1,
      audioFile: "old.m4a"
    )
    let recent = Dictation(
      createdAt: ago(60),
      rawText: "b",
      text: "recent",
      duration: 1,
      audioFile: "recent.m4a"
    )
    try await library.save(old)
    try await library.save(recent)
    #expect(folder.names(in: "dictation-audio") == ["old.m4a", "recent.m4a"])

    try await library.updateSettings { $0.historyRetention = .day }
    try await keepAudio(library, "new.m4a")
    let new = Dictation(rawText: "c", text: "new", duration: 1, audioFile: "new.m4a")
    try await library.save(new)
    #expect(try await library.dictations().map(\.text) == ["new", "recent"])
    #expect(folder.names(in: "dictation-audio") == ["new.m4a", "recent.m4a"])

    try await library.updateSettings { $0.historyRetention = .never }
    try await keepAudio(library, "last.m4a")
    try await library.save(Dictation(rawText: "d", text: "last", duration: 1, audioFile: "last.m4a"))
    #expect(try await library.dictations().isEmpty)
    #expect(folder.names(in: "dictation-audio").isEmpty)
    #expect(try text("dictations.json") == "[\n\n]\n")
  }

  @Test func deletingDictationsDeletesTheirAudio() async throws {
    let library = FileLibrary(root: folder.url)
    var saved: [Dictation] = []
    for name in ["a.m4a", "b.m4a", "c.m4a"] {
      try await keepAudio(library, name)
      let dictation = Dictation(rawText: name, text: name, duration: 1, audioFile: name)
      try await library.save(dictation)
      saved.append(dictation)
    }
    try await library.save(Dictation(rawText: "no audio", text: "no audio", duration: 1))

    try await library.deleteDictations([saved[0].id])
    #expect(folder.names(in: "dictation-audio") == ["b.m4a", "c.m4a"])

    // An entry whose audio is already gone can still be deleted.
    try FileManager.default.removeItem(at: folder.file("dictation-audio/b.m4a"))
    try await library.deleteDictations([saved[1].id])
    #expect(try await library.dictations().count == 2)

    try await library.deleteAllDictations()
    #expect(try await library.dictations().isEmpty)
    #expect(folder.names(in: "dictation-audio").isEmpty)
  }

  @Test func replacingADictationDropsAudioItNoLongerNames() async throws {
    let library = FileLibrary(root: folder.url)
    try await keepAudio(library, "retry.m4a")
    var dictation = Dictation(rawText: "", text: "", duration: 2, audioFile: "retry.m4a", failure: "Offline.")
    try await library.save(dictation)
    #expect(folder.exists("dictation-audio/retry.m4a"))

    dictation.text = "It worked the second time."
    dictation.failure = nil
    try await library.save(dictation)
    #expect(folder.exists("dictation-audio/retry.m4a"))

    dictation.audioFile = nil
    try await library.save(dictation)
    #expect(!folder.exists("dictation-audio/retry.m4a"))
  }

  @Test func deleteAllAlsoRemovesAudioNobodyPointsAtButNotARecordingInProgress() async throws {
    let library = FileLibrary(root: folder.url)
    try await keepAudio(library, "left-by-a-crash.m4a")
    try await keepAudio(library, "being-recorded.m4a")
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-3_600)],
      ofItemAtPath: folder.file("dictation-audio/left-by-a-crash.m4a").path
    )
    try await library.deleteAllDictations()
    #expect(folder.names(in: "dictation-audio") == ["being-recorded.m4a"])
  }

  @Test func anAudioNameCannotReachOutsideTheAudioFolder() async throws {
    let library = FileLibrary(root: folder.url)
    try await library.updateSettings { $0.userName = "Alex" }
    try folder.writeFromOutside("keep me", to: "precious.txt")
    let sneaky = ["../precious.txt", "../settings.json", "..", ".", "", "/etc/hosts"].map {
      Dictation(rawText: "x", text: "x", duration: 1, audioFile: $0)
    }
    for dictation in sneaky { try await library.save(dictation) }
    try await library.deleteDictations(Set(sneaky.prefix(3).map(\.id)))
    try await library.deleteAllDictations()
    #expect(folder.exists("precious.txt") && folder.exists("settings.json"))
    #expect(try await library.settings().userName == "Alex")
  }

  @Test func deletingAMeetingRemovesItsWholeFolder() async throws {
    let library = FileLibrary(root: folder.url)
    let keep = Meeting(title: "Keep", status: .ready)
    let drop = Meeting(title: "Drop", status: .ready)
    try await library.save(keep)
    try await library.save(drop)
    let audio = try await library.audioDirectory(forMeeting: drop.id)
    try Data("sound".utf8).write(to: audio.appendingPathComponent("microphone-0.m4a"))
    try Data("{}".utf8).write(to: audio.appendingPathComponent("manifest.json"))

    try await library.deleteMeeting(drop.id)
    #expect(folder.names(in: "meetings") == [keep.id.uuidString])

    // A meeting that only ever got as far as its audio folder goes too.
    let unsaved = UUID()
    _ = try await library.audioDirectory(forMeeting: unsaved)
    try await library.deleteMeeting(unsaved)
    #expect(folder.names(in: "meetings") == [keep.id.uuidString])
  }

  // MARK: Reading fast

  @Test func listingManyMeetingsDoesNotReadThemAgain() async throws {
    let library = FileLibrary(root: folder.url)
    let start = ago(100_000)
    let count = 1_500
    for index in 0..<count {
      try await library.save(
        Meeting(
          title: "Meeting \(index)",
          startedAt: start.addingTimeInterval(Double(index)),
          status: .ready,
          segments: [TranscriptSegment(speaker: .me, start: 0, end: 4, text: "Words about topic \(index).")]
        )
      )
    }
    // A second library starts with nothing in memory and has to read every file once.
    let reader = FileLibrary(root: folder.url)
    let clock = ContinuousClock()
    var first: [Meeting] = []
    let cold = try await clock.measure { first = try await reader.meetings() }
    #expect(first.count == count)
    #expect(first.first?.title == "Meeting \(count - 1)" && first.last?.title == "Meeting 0")

    var again: [Meeting] = []
    let rounds = 20
    let warm = try await clock.measure {
      for _ in 0..<rounds { again = try await reader.meetings() }
    }
    #expect(again == first)
    // Listing again only checks that nothing changed: far cheaper than reading it all.
    #expect(warm / rounds < cold / 4, "cold \(cold), warm \(warm / rounds) per listing")
    #expect(try await reader.meetings(search: "topic 1234.").map(\.title) == ["Meeting 1234"])

    // One meeting edited by another process shows up, and only that one is read again.
    var edited = try #require(first.last)
    edited.title = "Edited elsewhere"
    try await library.save(edited)
    #expect(try await reader.meetings().last?.title == "Edited elsewhere")
    #expect(try await reader.meeting(edited.id)?.title == "Edited elsewhere")
  }

  @Test func aFileEditedInPlaceIsNoticedEvenWithTheSameSize() async throws {
    let library = FileLibrary(root: folder.url)
    try await library.updateSettings { $0.userName = "Alex" }
    #expect(try await library.settings().userName == "Alex")
    let edited = try text("settings.json").replacingOccurrences(of: "\"Alex\"", with: "\"Sam!\"")
    try folder.writeFromOutside(edited, to: "settings.json")
    #expect(try await library.settings().userName == "Sam!")
  }
}
