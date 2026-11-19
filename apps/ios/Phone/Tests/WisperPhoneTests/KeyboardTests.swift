import Foundation
import Testing
import WisperDomain

@testable import WisperKeyboard

/// Records what the keyboard asked of the text field and the system.
@MainActor
final class KeyboardSpy {
  var typed = ""
  var opened: [URL] = []
  var switches = 0
  var fullAccess = true
  var canOpen = true

  var host: KeyboardHost {
    KeyboardHost(
      insert: { [self] text in typed += text },
      deleteBackward: { [self] in if !typed.isEmpty { typed.removeLast() } },
      nextKeyboard: { [self] in switches += 1 },
      open: { [self] url in
        opened.append(url)
        return canOpen
      },
      hasFullAccess: { [self] in fullAccess },
      needsGlobeKey: { false }
    )
  }
}

/// A library that cannot be read, as the shared folder is without Full Access.
private actor LockedLibrary: Library {
  private let refusal = WisperError.storage("Operation not permitted.")

  func settings() throws -> Settings { throw refusal }
  func updateSettings(_ change: @Sendable (inout Settings) -> Void) throws -> Settings { throw refusal }
  func words() throws -> [DictionaryWord] { throw refusal }
  func save(_ word: DictionaryWord) throws { throw refusal }
  func deleteWord(_ id: DictionaryWord.ID) throws { throw refusal }
  func snippets() throws -> [Snippet] { throw refusal }
  func save(_ snippet: Snippet) throws { throw refusal }
  func deleteSnippet(_ id: Snippet.ID) throws { throw refusal }
  func dictations(search: String?, limit: Int?) throws -> [Dictation] { throw refusal }
  func save(_ dictation: Dictation) throws { throw refusal }
  func deleteDictations(_ ids: Set<Dictation.ID>) throws { throw refusal }
  func deleteAllDictations() throws { throw refusal }
  func dictationAudioDirectory() throws -> URL { throw refusal }
  func meetings(search: String?) throws -> [Meeting] { throw refusal }
  func meeting(_ id: Meeting.ID) throws -> Meeting? { throw refusal }
  func save(_ meeting: Meeting) throws { throw refusal }
  func updateMeeting(_ id: Meeting.ID, _ change: @Sendable (inout Meeting) -> Void) throws -> Meeting? {
    throw refusal
  }
  func deleteMeeting(_ id: Meeting.ID) throws { throw refusal }
  func audioDirectory(forMeeting id: Meeting.ID) throws -> URL { throw refusal }
  nonisolated func changes() -> AsyncStream<LibraryChange> { AsyncStream { $0.finish() } }
}

@MainActor
@Suite struct KeyboardTests {
  private func library() -> InMemoryLibrary {
    let now = Date()
    return InMemoryLibrary(
      snippets: [
        Snippet(trigger: "my address", expansion: "1 Infinite Loop", createdAt: now.addingTimeInterval(-60)),
        Snippet(trigger: "sign off", expansion: "Thanks,\nAlex", createdAt: now),
      ],
      dictations: [
        Dictation(createdAt: now.addingTimeInterval(-90), rawText: "a", text: "Older text.", duration: 2),
        Dictation(createdAt: now.addingTimeInterval(-30), rawText: "b", text: "Newest text.", duration: 2),
        Dictation(createdAt: now, rawText: "", text: "", duration: 2, failure: "offline"),
      ]
    )
  }

  @Test func showsTheSnippetsAndTheLatestDictation() async {
    let spy = KeyboardSpy()
    let model = KeyboardModel(library: library(), host: spy.host)

    await model.refresh()
    #expect(model.snippets.map(\.trigger) == ["sign off", "my address"])
    // The newest entry failed and holds no text, so the one before it is the latest.
    #expect(model.latest == "Newest text.")
    #expect(model.problem == nil)
    #expect(!model.showsGlobeKey)
  }

  @Test func typesTheLatestDictationAndSnippets() async throws {
    let spy = KeyboardSpy()
    let model = KeyboardModel(library: library(), host: spy.host)
    await model.refresh()

    model.insertLatest()
    model.space()
    model.insert(try #require(model.snippets.last))
    model.newLine()
    #expect(spy.typed == "Newest text. 1 Infinite Loop\n")
  }

  @Test func saysSoWhenThereIsNothingToInsert() async {
    let spy = KeyboardSpy()
    let model = KeyboardModel(library: InMemoryLibrary(), host: spy.host)
    await model.refresh()

    model.insertLatest()
    #expect(spy.typed.isEmpty)
    #expect(model.hint?.contains("Nothing dictated yet") == true)

    model.space()
    #expect(model.hint == nil)
  }

  @Test func theDictateKeyOpensTheAppToListen() async {
    let spy = KeyboardSpy()
    let model = KeyboardModel(library: library(), host: spy.host)

    await model.dictate()
    #expect(spy.opened == [WisperLink.toggleDictation.url])
    #expect(model.hint == nil)
  }

  @Test func theDictateKeyLeavesATicketTheAppCanRedeemOnce() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("wisper-keyboard-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let spy = KeyboardSpy()
    let model = KeyboardModel(library: library(), dataFolder: folder, host: spy.host)

    await model.dictate()
    let opened = try #require(spy.opened.first)
    #expect(WisperLink(opened) == .toggleDictation)
    let ticket = try #require(WisperLink.ticket(in: opened))
    #expect(LinkTicket.redeem(ticket, in: folder))
    #expect(!LinkTicket.redeem(ticket, in: folder))
  }

  @Test func aFolderThatCannotBeWrittenStillOpensTheApp() async throws {
    // A file where the folder should be: no ticket can be left there.
    let blocked = FileManager.default.temporaryDirectory
      .appendingPathComponent("wisper-keyboard-tests-\(UUID().uuidString)")
    try Data().write(to: blocked)
    defer { try? FileManager.default.removeItem(at: blocked) }
    let spy = KeyboardSpy()
    let model = KeyboardModel(library: library(), dataFolder: blocked, host: spy.host)

    await model.dictate()
    #expect(spy.opened == [WisperLink.toggleDictation.url])
    #expect(model.hint == nil)
  }

  @Test func explainsWhenTheAppCannotBeOpened() async {
    let spy = KeyboardSpy()
    spy.canOpen = false
    let model = KeyboardModel(library: library(), host: spy.host)

    await model.dictate()
    #expect(model.hint?.contains("Open the app") == true)

    spy.fullAccess = false
    await model.dictate()
    #expect(model.hint?.contains("Allow Full Access") == true)
  }

  @Test func withoutTheSharedFolderItExplainsInsteadOfCrashing() async {
    let spy = KeyboardSpy()
    let model = KeyboardModel(library: nil, host: spy.host)

    await model.refresh()
    #expect(model.problem == .noSharedFolder)
    #expect(model.snippets.isEmpty)
    #expect(model.latest == nil)
  }

  @Test func asksForFullAccessWhenItIsOff() async {
    let spy = KeyboardSpy()
    spy.fullAccess = false

    // iOS may still let the keyboard read: the snippets work, the notice stays.
    let readable = KeyboardModel(library: library(), host: spy.host)
    await readable.refresh()
    #expect(readable.problem == .needsFullAccess)
    #expect(readable.latest == "Newest text.")

    // Or it may not: then the notice is the whole story.
    let locked = KeyboardModel(library: LockedLibrary(), host: spy.host)
    await locked.refresh()
    #expect(locked.problem == .needsFullAccess)
    #expect(locked.snippets.isEmpty)
  }

  @Test func aLibraryThatCannotBeReadIsReported() async {
    let spy = KeyboardSpy()
    let model = KeyboardModel(library: LockedLibrary(), host: spy.host)

    await model.refresh()
    guard case .cannotRead(let message) = model.problem else {
      Issue.record("Expected the read failure to be reported.")
      return
    }
    #expect(message.contains("Operation not permitted"))
  }

  @Test func holdingDeleteKeepsDeleting() async {
    let spy = KeyboardSpy()
    spy.typed = String(repeating: "x", count: 40)
    let model = KeyboardModel(library: nil, host: spy.host)
    model.repeatDelay = .milliseconds(20)
    model.repeatInterval = .milliseconds(5)

    model.deleteBegan()
    #expect(spy.typed.count == 39)
    try? await Task.sleep(for: .milliseconds(150))
    model.deleteEnded()
    let afterHold = spy.typed.count
    #expect(afterHold < 37)

    // Nothing more goes once the key is up.
    try? await Task.sleep(for: .milliseconds(60))
    #expect(spy.typed.count == afterHold)
  }

  @Test func aTapOnDeleteRemovesOneCharacter() async {
    let spy = KeyboardSpy()
    spy.typed = "abc"
    let model = KeyboardModel(library: nil, host: spy.host)

    model.deleteBegan()
    model.deleteEnded()
    try? await Task.sleep(for: .milliseconds(30))
    #expect(spy.typed == "ab")
  }

  @Test func theGlobeKeySwitchesKeyboards() {
    let spy = KeyboardSpy()
    let model = KeyboardModel(library: nil, host: spy.host)
    model.nextKeyboard()
    #expect(spy.switches == 1)
  }
}

@Suite struct SharedFolderTests {
  private func scratch() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("wisper-phone-tests-\(UUID().uuidString)", isDirectory: true)
  }

  @Test func usesTheAppGroupWhenThereIsOne() {
    let container = scratch()
    var asked: [String] = []
    let folder = SharedFolder(environment: [:]) { group in
      asked.append(group)
      return container
    }
    #expect(asked == ["group.dev.openwisper"])
    #expect(folder.isShared)
    #expect(folder.root == container.appendingPathComponent("Open Wisper", isDirectory: true))
  }

  @Test func fallsBackToTheAppsOwnFolder() {
    let folder = SharedFolder(environment: [:]) { _ in nil }
    #expect(!folder.isShared)
    #expect(folder.root == WisperPaths.defaultRoot(environment: [:]))
  }

  @Test func theEnvironmentVariableWins() {
    let home = scratch()
    let folder = SharedFolder(environment: [WisperPaths.homeVariable: home.path]) { _ in self.scratch() }
    #expect(!folder.isShared)
    #expect(folder.root.path == home.path)
  }

  @Test func offThePhoneThereIsNoAppGroup() {
    #if !os(iOS)
      #expect(SharedFolder.systemContainer(SharedFolder.groupID) == nil)
    #endif
  }

  @Test func adoptsALibraryLeftInTheAppsOwnFolder() throws {
    let files = FileManager.default
    let base = scratch()
    defer { try? files.removeItem(at: base) }
    let old = base.appendingPathComponent("private/Open Wisper", isDirectory: true)
    let container = base.appendingPathComponent("group", isDirectory: true)
    try files.createDirectory(at: old, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: old.appendingPathComponent("settings.json"))

    let folder = SharedFolder(environment: [:]) { _ in container }
    folder.adoptLibrary(from: old)
    #expect(!files.fileExists(atPath: old.path))
    #expect(files.fileExists(atPath: folder.root.appendingPathComponent("settings.json").path))

    // A library already in the shared folder is never replaced.
    try files.createDirectory(at: old, withIntermediateDirectories: true)
    try Data("other".utf8).write(to: old.appendingPathComponent("settings.json"))
    folder.adoptLibrary(from: old)
    #expect(files.fileExists(atPath: old.path))
    let kept = try Data(contentsOf: folder.root.appendingPathComponent("settings.json"))
    #expect(kept == Data("{}".utf8))
  }

  @Test func adoptsNothingWithoutAnAppGroup() throws {
    let files = FileManager.default
    let old = scratch()
    defer { try? files.removeItem(at: old) }
    try files.createDirectory(at: old, withIntermediateDirectories: true)

    SharedFolder(environment: [:]) { _ in nil }.adoptLibrary(from: old)
    #expect(files.fileExists(atPath: old.path))
  }
}
