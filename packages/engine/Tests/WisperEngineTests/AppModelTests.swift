import Foundation
import Observation
import Testing
import WisperDomain
import WisperStore

@testable import WisperEngine

/// An app model on fakes, with the parts a test wants to steer.
@MainActor
private func makeModel(
  library: any Library,
  secrets: any SecretStore = InMemorySecretStore(),
  transcriber: FakeTranscriber = FakeTranscriber(text: "hello world"),
  host: HostActions = HostActions(),
  checkAPIKey: @escaping @Sendable (String) async throws -> Void = { _ in }
) -> AppModel {
  AppModel(
    AppModel.Dependencies(
      library: library,
      secrets: secrets,
      capture: FakeAudioCapture(),
      transcriber: transcriber,
      languageModel: echoingModel(),
      target: FakeTextTarget(),
      permissions: FakePermissions(),
      host: host,
      checkAPIKey: checkAPIKey
    )
  )
}

/// Writes down every value a setting takes on screen, in order.
@MainActor
private final class Watcher {
  private(set) var seen: [String] = []
  private let model: AppModel

  init(_ model: AppModel) {
    self.model = model
    watch()
  }

  private func watch() {
    withObservationTracking {
      _ = model.settings.userName
    } onChange: {
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.seen.append(self.model.settings.userName)
        self.watch()
      }
    }
  }
}

@MainActor
@Suite("AppModel: settings on screen", .timeLimit(.minutes(1)))
struct AppModelSettingsTests {
  @Test func aSettingNeverJumpsBackToAnOlderValue() async throws {
    let library = ScriptedLibrary()
    let model = makeModel(library: library)
    await model.load()
    let watcher = Watcher(model)

    // From here on a read of the settings is slow: it takes the value and then waits.
    let slowDisk = Gate()
    await library.holdSettingsReads(at: slowDisk)
    model.update { $0.userName = "A" }
    #expect(model.settings.userName == "A")
    // A read that saw "A" is now on its way back...
    await slowDisk.arrival()
    // ...when the next key is typed.
    model.update { $0.userName = "AB" }
    #expect(model.settings.userName == "AB")
    #expect(await eventually { await library.storedName() == "AB" })

    // The old read lands. What is on screen is newer and must stay.
    await slowDisk.open()
    #expect(await eventually { await library.settingsReadsUnderWay == 0 })
    for _ in 0..<20 {
      await Task.yield()
      #expect(model.settings.userName == "AB")
    }
    #expect(watcher.seen.drop { $0 != "AB" }.allSatisfy { $0 == "AB" }, "\(watcher.seen)")
    #expect(model.errorMessage == nil)
  }

  @Test func changesAreStoredInTheOrderTheyWereMade() async throws {
    let library = ScriptedLibrary()
    let model = makeModel(library: library)
    await model.load()

    let names = ["A", "AB", "ABC", "ABCD", "ABCDE"]
    for name in names { model.update { $0.userName = name } }

    #expect(model.settings.userName == "ABCDE")
    #expect(await eventually { await library.namesStored.count == names.count })
    #expect(await library.namesStored == names)
    #expect(await eventually { await library.settingsReadsUnderWay == 0 })
    #expect(model.settings.userName == "ABCDE")
  }

  @Test func aChangeThatCannotBeStoredDoesNotStayOnScreen() async throws {
    let library = ScriptedLibrary(InMemoryLibrary(settings: Settings(userName: "Stored")))
    let told = Shared<[Bool]>([])
    let model = makeModel(
      library: library,
      host: HostActions(setLaunchAtLogin: { value in _ = told.exchange { $0.append(value) } })
    )
    await model.load()
    await library.failSettingsWrites(true)

    model.update {
      $0.userName = "Typed"
      $0.launchAtLogin = true
    }
    // At once, as always.
    #expect(model.settings.userName == "Typed")

    #expect(await eventually { model.settings.userName == "Stored" })
    #expect(!model.settings.launchAtLogin)
    #expect(model.errorMessage == ScriptedLibrary.refusal.errorDescription)
    // The system was told to open the app at login, then told to stop again.
    #expect(await eventually { told.value == [true, false] })

    // Once the disk works again, changes stick.
    await library.failSettingsWrites(false)
    model.update { $0.userName = "Typed" }
    #expect(await eventually { await library.storedName() == "Typed" })
    #expect(model.settings.userName == "Typed")
  }

  @Test func aChangeMadeByAnAgentStillShowsUp() async throws {
    let library = InMemoryLibrary()
    let model = makeModel(library: library)
    await model.load()

    model.update { $0.userName = "Alex" }
    #expect(await eventually { await library.settings().userName == "Alex" })
    await library.updateSettings { $0.playSounds = false }

    #expect(await eventually { !model.settings.playSounds })
    #expect(model.settings.userName == "Alex")
  }

  @Test func errorsNameTheCustomServer() async throws {
    let model = makeModel(library: InMemoryLibrary(settings: Settings(apiBaseURL: "http://localhost:11434")))
    await model.load()

    await model.attempt { _ in throw WisperError.network("the server did not answer") }

    let message = try #require(model.errorMessage)
    #expect(message.hasPrefix("Could not reach localhost."))
    #expect(!message.contains("OpenAI"))
  }
}

@MainActor
@Suite("AppModel: the key belongs to one server", .timeLimit(.minutes(1)))
struct AppModelKeyTests {
  @Test func hasAPIKeyIsAboutTheServerTheSettingsName() async throws {
    let library = InMemoryLibrary()
    let model = makeModel(library: library, secrets: InMemorySecretStore(apiKey: "sk-openai"))
    #expect(!model.hasAPIKey)
    await model.load()
    #expect(model.hasAPIKey)

    // Changed in Settings.
    model.update { $0.apiBaseURL = "http://localhost:11434" }
    #expect(await eventually { !model.hasAPIKey })
    model.update { $0.apiBaseURL = nil }
    #expect(await eventually { model.hasAPIKey })

    // Changed behind the app's back, by an agent or a hand edit of the settings file.
    await library.updateSettings { $0.apiBaseURL = "https://collector.example.net/v1" }
    #expect(await eventually { !model.hasAPIKey })
    #expect(model.settings.apiBaseURL == "https://collector.example.net/v1")
    // An address that cannot be used has no key either.
    await library.updateSettings { $0.apiBaseURL = "localhost:11434" }
    #expect(await eventually { model.settings.apiBaseURL == "localhost:11434" })
    #expect(!model.hasAPIKey)
    await library.updateSettings { $0.apiBaseURL = "https://API.OpenAI.com/v1" }
    #expect(await eventually { model.hasAPIKey })
  }

  @Test func aKeySavedForACustomServerCountsOnlyThere() async throws {
    let library = InMemoryLibrary(settings: Settings(apiBaseURL: "https://gateway.example.com/v1"))
    let secrets = InMemorySecretStore(apiKey: "sk-gateway", host: "gateway.example.com")
    let model = makeModel(library: library, secrets: secrets)
    await model.load()
    #expect(model.hasAPIKey)

    // The settings forget the server (a damaged settings file recovers to the defaults).
    await library.updateSettings { $0.apiBaseURL = nil }
    #expect(await eventually { !model.hasAPIKey })
    #expect(await secrets.apiKey(for: APIServer.openAIHost) == nil)
  }

  @Test func aKeyIsSavedForTheServerTheSettingsName() async throws {
    let library = InMemoryLibrary()
    let secrets = InMemorySecretStore()
    let checked = Shared<[String]>([])
    let model = makeModel(library: library, secrets: secrets) { key in
      _ = checked.exchange { $0.append(key) }
      if key == "sk-wrong" { throw WisperError.invalidAPIKey }
    }
    await model.load()

    try await model.saveAPIKey("  sk-openai \n")
    #expect(model.hasAPIKey)
    #expect(await secrets.apiKey(for: "api.openai.com") == "sk-openai")

    // The way the first-run screen does it: the address goes straight to the library, and
    // the key is saved right after, before the model has heard of the change.
    await library.updateSettings { $0.apiBaseURL = "https://Gateway.Example.com/v1" }
    try await model.saveAPIKey("sk-gateway")
    #expect(model.hasAPIKey)
    #expect(model.settings.apiBaseURL == "https://Gateway.Example.com/v1")
    #expect(await secrets.apiKey(for: "gateway.example.com") == "sk-gateway")
    #expect(await secrets.apiKey(for: "api.openai.com") == nil)

    // The way the settings screen does it: a change through the model, then the key.
    model.update { $0.apiBaseURL = "http://localhost:11434" }
    try await model.saveAPIKey("sk-local")
    #expect(await secrets.apiKey(for: "localhost") == "sk-local")
    #expect(await secrets.apiKey(for: "gateway.example.com") == nil)
    #expect(model.hasAPIKey)

    // A key the server turns down is not saved.
    await #expect(throws: WisperError.invalidAPIKey) { try await model.saveAPIKey("sk-wrong") }
    #expect(await secrets.apiKey(for: "localhost") == "sk-local")
    await #expect(throws: WisperError.missingAPIKey) { try await model.saveAPIKey("  ") }
    #expect(checked.value == ["sk-openai", "sk-gateway", "sk-local", "sk-wrong"])

    await model.removeAPIKey()
    #expect(!model.hasAPIKey)
    #expect(await secrets.apiKey(for: "localhost") == nil)
  }

  @Test func aKeyIsNotCheckedOrSavedWhenTheServerAddressCannotBeUsed() async throws {
    let library = InMemoryLibrary(settings: Settings(apiBaseURL: "127.0.0.1:63570/v1"))
    let secrets = InMemorySecretStore()
    let checked = Shared(0)
    let model = makeModel(library: library, secrets: secrets) { _ in _ = checked.exchange { $0 += 1 } }
    await model.load()

    await #expect(throws: WisperError.invalidServerAddress) { try await model.saveAPIKey("sk-new") }

    #expect(checked.value == 0)
    #expect(!model.hasAPIKey)
    #expect(await secrets.apiKey(for: "api.openai.com") == nil)
    #expect(await secrets.apiKey(for: "127.0.0.1") == nil)
  }
}

@Suite("AppModel: an unusable server address sends nothing", .timeLimit(.minutes(1)))
struct AppModelServerAddressTests {
  @Test(arguments: ["127.0.0.1:63570/v1", "localhost:11434", "ftp://example.com/v1"])
  func nothingIsTranscribedOrAskedWhileTheAddressCannotBeUsed(address: String) async throws {
    let library = InMemoryLibrary(settings: Settings(apiBaseURL: address))
    let transcriber = FakeTranscriber(text: "must not be heard")
    let model = FakeLanguageModel(text: "must not be asked")
    let checked = AddressChecked(library: library, transcriber: transcriber, languageModel: model)
    let audio = URL(fileURLWithPath: "/nonexistent/meeting-chunk.m4a")

    await #expect(throws: WisperError.invalidServerAddress) {
      _ = try await checked.transcribe(TranscriptionRequest(audio: audio, model: "gpt-transcribe"))
    }
    await #expect(throws: WisperError.invalidServerAddress) {
      _ = try await checked.complete(CompletionRequest(model: "m", system: "", user: "notes, please"))
    }
    #expect(transcriber.requests.isEmpty)
    #expect(model.requests.isEmpty)

    // Put right (or cleared), requests go through again.
    for fixed in ["http://127.0.0.1:63570/v1", nil] as [String?] {
      await library.updateSettings { $0.apiBaseURL = fixed }
      let heard = try await checked.transcribe(TranscriptionRequest(audio: audio, model: "gpt-transcribe"))
      #expect(heard.text == "must not be heard")
      #expect(
        try await checked.complete(CompletionRequest(model: "m", system: "", user: "hi"))
          == "must not be asked"
      )
    }
    #expect(transcriber.requests.count == 2)
  }

  @MainActor
  @Test func theAppModelPutsTheCheckInFrontOfBothEngines() async throws {
    // Through the app model, a dictation with an unusable address fails before the transcriber.
    let transcriber = FakeTranscriber(text: "must not be heard")
    let model = makeModel(
      library: InMemoryLibrary(settings: Settings(apiBaseURL: "127.0.0.1:63570/v1")),
      transcriber: transcriber
    )
    await model.load()
    model.dictation.start()
    #expect(await model.dictation.finish() == nil)
    #expect(
      model.dictation.phase
        == .failed(message: "The custom server address in Settings is not a valid web address.")
    )
    #expect(transcriber.requests.isEmpty)
  }
}

@MainActor
@Suite("AppModel: dictations after a quit, on the real file library", .timeLimit(.minutes(1)))
struct AppModelDictationTests {
  @Test func theFirstLoadTidiesUpAfterAQuit() async throws {
    let folder = TemporaryFolder()
    let library = FileLibrary(root: folder.url)
    try await library.updateSettings { $0.historyRetention = .never }
    let audio = try await library.dictationAudioDirectory()
    // What a quit in the middle of a dictation leaves when history is off.
    try Data("audio".utf8).write(to: audio.appendingPathComponent("\(UUID().uuidString).m4a"))
    #expect(folder.audioFiles.count == 1)

    let model = makeModel(library: library)
    await model.load()

    #expect(folder.audioFiles.isEmpty)
    #expect(model.isLoaded)
  }

  @Test func theEntryOfADictationInProgressIsNotShownAsAFailure() async throws {
    let folder = TemporaryFolder()
    let library = FileLibrary(root: folder.url)
    let listening = Gate()
    let model = makeModel(
      library: library,
      transcriber: FakeTranscriber { _ in
        await listening.pass()
        return Transcript(text: "the words arrive")
      }
    )
    await model.load()

    model.dictation.start()
    let finishing = Task { await model.dictation.finish() }
    await listening.arrival()

    // On disk there is an entry, in case the app quits now.
    #expect(try await library.dictations().map(\.failed) == [true])
    // Changes arrive in order, so once this word shows, the dictation's entry has been seen too.
    try await library.save(DictionaryWord(text: "Marker"))
    #expect(await eventually { model.words.map(\.text) == ["Marker"] })
    #expect(model.dictations.isEmpty)

    await listening.open()
    let done = try #require(await finishing.value)
    #expect(await eventually { model.dictations == [done] })
    #expect(model.stats.dictationCount == 1)
  }

  @Test func anEntryLeftByAQuitIsShownAfterTheNextLaunch() async throws {
    let folder = TemporaryFolder()
    let library = FileLibrary(root: folder.url)
    let audio = try await library.dictationAudioDirectory()
    try Data("audio".utf8).write(to: audio.appendingPathComponent("left.m4a"))
    let left = Dictation(
      rawText: "",
      text: "",
      duration: 3,
      audioFile: "left.m4a",
      failure: "Open Wisper closed before this dictation was finished. Try it again."
    )
    try await library.save(left)

    let model = makeModel(library: FileLibrary(root: folder.url))
    await model.load()

    #expect(model.dictations.map(\.id) == [left.id])
    #expect(folder.audioFiles == ["left.m4a"])
    let fixed = try #require(await model.dictation.retry(left.id, insert: false))
    #expect(fixed.text == "Hello world")
  }
}
