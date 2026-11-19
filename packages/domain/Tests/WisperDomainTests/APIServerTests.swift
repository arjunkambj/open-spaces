import Foundation
import Testing

@testable import WisperDomain

@Suite("Which server an address means, and who may have the key")
struct APIServerTests {
  @Test(arguments: [nil, "", "   ", "\n"] as [String?])
  func noAddressMeansOpenAI(address: String?) throws {
    let server = try APIServer(address: address)
    #expect(server == .openAI)
    #expect(server.isOpenAI)
    #expect(server.host == "api.openai.com")
    #expect(server.root.absoluteString == "https://api.openai.com/v1")
  }

  @Test(
    arguments: [
      ("https://api.openai.com/v1/", "https://api.openai.com/v1", "api.openai.com"),
      ("http://localhost:11434", "http://localhost:11434/v1", "localhost"),
      ("http://localhost:11434/", "http://localhost:11434/v1", "localhost"),
      (" http://127.0.0.1:8080/v1 \n", "http://127.0.0.1:8080/v1", "127.0.0.1"),
      ("https://example.com/openai/v1///", "https://example.com/openai/v1", "example.com"),
      ("https://gateway.example.com/api", "https://gateway.example.com/api", "gateway.example.com"),
      ("https://example.com/v1/?version=2", "https://example.com/v1?version=2", "example.com"),
      ("HTTPS://Example.COM:8443", "https://example.com:8443/v1", "example.com"),
      (
        "https://alex:secret@proxy.example.com/v1", "https://alex:secret@proxy.example.com/v1",
        "proxy.example.com"
      ),
    ]
  )
  func aWebAddressIsTakenAsTheFolderOfTheAPI(address: String, root: String, host: String) throws {
    let server = try APIServer(address: address)
    #expect(server.root.absoluteString == root)
    #expect(server.host == host)
    #expect(server.isOpenAI == (host == "api.openai.com"))
  }

  @Test(arguments: [
    "127.0.0.1:63570/v1", "localhost:11434", "not a url", "ftp://example.com/v1", "http://", "https:///v1",
    "example.com", "http://exa mple.com/v1", "file:///tmp/server",
  ])
  func anAddressThatIsSetButUnusableIsAnErrorAndNeverOpenAI(address: String) {
    #expect(throws: WisperError.invalidServerAddress) { try APIServer(address: address) }
    #expect(throws: WisperError.invalidServerAddress) { try Settings(apiBaseURL: address).apiServer() }
  }

  @Test func settingsNameTheirServer() throws {
    #expect(try Settings().apiServer() == .openAI)
    #expect(try Settings(apiBaseURL: "http://localhost:11434").apiServer().host == "localhost")
  }

  @Test func hostNamesAreComparedWithoutCase() {
    #expect(APIServer.sameHost("API.OpenAI.com", "api.openai.com"))
    #expect(APIServer.sameHost(" localhost\n", "LOCALHOST"))
    #expect(!APIServer.sameHost("api.openai.com", "api.openai.com.evil.example"))
    #expect(!APIServer.sameHost("openai.com", "api.openai.com"))
  }

  // MARK: The key belongs to one host

  @Test func aKeyIsOnlyHandedOutForTheHostItWasSavedFor() async throws {
    let store = InMemorySecretStore()
    #expect(await store.apiKey(for: "api.openai.com") == nil)

    await store.setAPIKey("test-key", host: "Gateway.Example.com")
    #expect(await store.apiKey(for: "gateway.example.com") == "test-key")
    #expect(await store.apiKey(for: "GATEWAY.EXAMPLE.COM") == "test-key")
    #expect(await store.apiKey(for: "api.openai.com") == nil)
    #expect(await store.apiKey(for: "example.com") == nil)

    // Saving for another host replaces the key: there is only ever one.
    await store.setAPIKey("other-key", host: "api.openai.com")
    #expect(await store.apiKey(for: "gateway.example.com") == nil)
    #expect(await store.apiKey(for: "api.openai.com") == "other-key")

    // Removing does not ask which host.
    await store.setAPIKey(nil, host: "somewhere.else")
    #expect(await store.apiKey(for: "api.openai.com") == nil)
  }

  @Test func theOldEntryPointsMeanOpenAI() async throws {
    let store: any SecretStore = InMemorySecretStore(apiKey: "test-key")
    #expect(try await store.apiKey() == "test-key")
    #expect(try await store.apiKey(for: APIServer.openAIHost) == "test-key")
    #expect(try await store.apiKey(for: "localhost") == nil)

    try await store.setAPIKey("second-key")
    #expect(try await store.apiKey(for: "api.openai.com") == "second-key")

    let custom: any SecretStore = InMemorySecretStore(apiKey: "local-key", host: "localhost")
    #expect(try await custom.apiKey() == nil)
    #expect(try await custom.apiKey(for: "localhost") == "local-key")
    try await custom.setAPIKey(nil)
    #expect(try await custom.apiKey(for: "localhost") == nil)
  }

  // MARK: Wording

  @Test func errorsNameTheServerThePersonSet() throws {
    let local = try APIServer(address: "http://127.0.0.1:8080/v1")
    let errors: [WisperError] = [
      .invalidAPIKey, .rateLimited, .network("the server did not answer"),
      .server(status: 500, message: "try later"), .invalidResponse("the answer was missing"), .missingAPIKey,
    ]
    for error in errors {
      let message = error.message(server: local)
      #expect(message.contains("127.0.0.1"), "\(message)")
      #expect(!message.contains("OpenAI"), "\(message)")
      #expect(!message.localizedCaseInsensitiveContains("internet connection"), "\(message)")
      // For OpenAI itself nothing changes.
      #expect(error.message(server: .openAI) == error.errorDescription)
    }
    #expect(
      WisperError.network("the server did not answer").message(server: local)
        == "Could not reach 127.0.0.1. Check that the server is running and the address in Settings is right."
        + " (the server did not answer)"
    )
    // Errors that are not about a server read the same everywhere.
    for error in [WisperError.noSpeech, .permissionDenied(.microphone), .storage("x"), .invalidServerAddress]
    {
      #expect(error.message(server: local) == error.errorDescription)
    }
    #expect(
      WisperError.invalidServerAddress.errorDescription
        == "The custom server address in Settings is not a valid web address."
    )
  }
}

@Suite("Files written by a newer version")
struct NewerVersionTests {
  private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(json.utf8))
  }

  @Test func aMeetingWithAnUnknownStatusStillLoads() throws {
    let meeting = try decode(
      Meeting.self,
      """
      {"id": "00000000-0000-4000-8000-000000000001", "title": "Future", "startedAt": "2026-11-17T09:30:00Z",
       "status": "paused", "userNotes": "keep me", "futureField": {"a": 1}}
      """
    )
    #expect(meeting.status == .ready)
    #expect(meeting.title == "Future")
    #expect(meeting.userNotes == "keep me")
  }

  @Test func aDictationWithAnUnknownModeStillLoads() throws {
    let dictation = try decode(
      Dictation.self,
      """
      {"id": "00000000-0000-4000-8000-000000000002", "createdAt": "2026-11-17T09:30:00Z", "mode": "translate",
       "rawText": "hola", "text": "hello", "duration": 2}
      """
    )
    #expect(dictation.mode == .dictation)
    #expect(dictation.text == "hello")
    #expect(dictation.selection == nil)
  }

  @Test func settingsSkipChoicesThisVersionDoesNotKnow() throws {
    let settings = try decode(
      Settings.self,
      """
      {"userName": "Sam", "historyRetention": "year",
       "styles": {"email": "poetic", "other": "veryCasual", "futureCategory": "formal"},
       "shortcuts": {"pushToTalk": {"modifiers": ["hyper"]}, "handsFree": {"keyCode": 49, "modifiers": ["option"]}}}
      """
    )
    #expect(settings.userName == "Sam")
    #expect(settings.historyRetention == .forever)
    #expect(settings.styles[.email] == Settings.defaultStyles[.email])
    #expect(settings.styles[.other] == .veryCasual)
    // A shortcut with a key this version does not know keeps its default, whole.
    #expect(settings.shortcuts[.pushToTalk] == Settings.defaultShortcuts[.pushToTalk])
    #expect(settings.shortcuts[.handsFree] == KeyCombo(keyCode: 49, modifiers: [.option]))
  }

  @Test func theSelectionOfAFailedCommandSurvivesARoundTrip() throws {
    let failed = Dictation(
      mode: .command,
      rawText: "make this shorter",
      text: "",
      duration: 2,
      audioFile: "a.m4a",
      failure: "offline",
      selection: "A long paragraph."
    )
    let data = try JSONEncoder().encode(failed)
    #expect(try JSONDecoder().decode(Dictation.self, from: data) == failed)

    // Entries without a selection do not carry the key at all.
    let plain = try JSONEncoder().encode(Dictation(rawText: "hi", text: "Hi", duration: 1))
    #expect(!String(decoding: plain, as: UTF8.self).contains("selection"))
  }
}
