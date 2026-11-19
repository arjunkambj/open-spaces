import Foundation
import Testing
import WisperDomain

@testable import WisperAI

/// What every call shares: where requests go, the key, errors, retries, cancelling.
@Suite struct OpenAITests {
  static let hello = LanguageModelTests.reply("Hello.")
  static let prompt = CompletionRequest(model: "m", system: "", user: "hi")
  let recordings: Recordings

  init() throws { recordings = try Recordings() }

  // MARK: Where requests go

  @Test(
    arguments: [
      (nil, "https://api.openai.com/v1/chat/completions"),
      ("https://api.openai.com/v1", "https://api.openai.com/v1/chat/completions"),
      ("https://api.openai.com/v1/", "https://api.openai.com/v1/chat/completions"),
      // No path at all: `/v1` is added.
      ("http://localhost:11434", "http://localhost:11434/v1/chat/completions"),
      ("http://localhost:11434/", "http://localhost:11434/v1/chat/completions"),
      ("http://localhost:11434/v1", "http://localhost:11434/v1/chat/completions"),
      ("http://localhost:11434/v1/", "http://localhost:11434/v1/chat/completions"),
      // Any other path is taken as it is.
      ("https://example.com/openai/v1///", "https://example.com/openai/v1/chat/completions"),
      ("https://gateway.example.com/api", "https://gateway.example.com/api/chat/completions"),
      // What follows a "?" is kept.
      ("https://example.com/v1/?version=2", "https://example.com/v1/chat/completions?version=2"),
      ("HTTPS://Example.COM:8443", "https://example.com:8443/v1/chat/completions"),
      // Only white space: nothing was set.
      ("  \n", "https://api.openai.com/v1/chat/completions"),
    ] as [(String?, String)]
  )
  func buildsTheAddressFromTheCustomServer(custom: String?, expected: String) async throws {
    let server = Server(Self.hello)

    _ = try await server.openAI(baseURL: custom).languageModel.complete(Self.prompt)

    #expect(server.requests.first?.url.absoluteString == expected)
  }

  @Test(arguments: ["127.0.0.1:63570/v1", "not a url", "ftp://example.com/v1", "localhost:11434", "http://"])
  func anAddressThatIsSetButUnusableIsAnErrorAndNothingIsSentAnywhere(address: String) async throws {
    let server = Server(Self.hello)
    // A key for OpenAI is saved, so a quiet fallback to OpenAI would have everything it needs.
    let openAI = server.openAI(secrets: InMemorySecretStore(apiKey: "sk-openai")) { address }
    let audio = try recordings.file()

    let chat = await wisperError { _ = try await openAI.languageModel.complete(Self.prompt) }
    let speech = await wisperError {
      _ = try await openAI.transcriber.transcribe(TranscriptionRequest(audio: audio, model: "gpt-transcribe"))
    }
    let check = await wisperError { try await openAI.check(key: "sk-new") }

    #expect(chat == .invalidServerAddress)
    #expect(speech == .invalidServerAddress)
    #expect(check == .invalidServerAddress)
    #expect(server.requests.isEmpty)
  }

  @Test func settingsThatCannotBeReadSendNothing() async throws {
    let server = Server(Self.hello)
    let openAI = server.openAI(secrets: InMemorySecretStore(apiKey: "sk-openai")) {
      throw WisperError.storage("settings.json could not be opened.")
    }

    let error = await wisperError { _ = try await openAI.languageModel.complete(Self.prompt) }

    #expect(error == .storage("settings.json could not be opened."))
    #expect(server.requests.isEmpty)
  }

  @Test func theEarlierURLEntryPointStillWorksAndStillRefusesABadAddress() async throws {
    let server = Server(Self.hello)
    let secrets = InMemorySecretStore(apiKey: "sk-local", host: "localhost")
    let address = Address()
    await address.set("http://localhost:11434")
    let openAI = OpenAI(
      secrets: secrets,
      baseURL: { await address.text.flatMap(URL.init(string:)) },
      session: server.session
    )

    _ = try await openAI.languageModel.complete(Self.prompt)
    #expect(server.requests.map(\.url.absoluteString) == ["http://localhost:11434/v1/chat/completions"])
    #expect(server.requests.first?.header("Authorization") == "Bearer sk-local")

    await address.set("ftp://example.com/v1")
    let error = await wisperError { _ = try await openAI.languageModel.complete(Self.prompt) }
    #expect(error == .invalidServerAddress)
    #expect(server.requests.count == 1)
  }

  @Test func readsTheServerAndTheKeyAgainForEveryRequest() async throws {
    let server = Server(Self.hello)
    let secrets = InMemorySecretStore(apiKey: "sk-first")
    let address = Address()
    let model = server.openAI(secrets: secrets) { await address.text }.languageModel

    _ = try await model.complete(Self.prompt)
    await secrets.setAPIKey("sk-second", host: "localhost")
    await address.set("http://localhost:9000/v1")
    _ = try await model.complete(Self.prompt)

    #expect(server.requests.map { $0.header("Authorization") } == ["Bearer sk-first", "Bearer sk-second"])
    #expect(server.requests.map(\.url.host) == ["api.openai.com", "localhost"])
  }

  actor Address {
    var text: String?
    func set(_ text: String?) { self.text = text }
  }

  // MARK: The key goes only to the server it was saved for

  @Test func aKeySavedForOpenAIIsNotSentToAnotherServerAndComesBackWithTheSetting() async throws {
    let server = Server(Self.hello)
    let address = Address()
    let openAI = server.openAI(secrets: InMemorySecretStore(apiKey: "sk-openai")) { await address.text }
    let audio = try recordings.file()

    _ = try await openAI.languageModel.complete(Self.prompt)
    // One line changed in the settings file: another server.
    await address.set("https://collector.example.net/v1")
    _ = try await openAI.languageModel.complete(Self.prompt)
    _ = try? await openAI.transcriber.transcribe(TranscriptionRequest(audio: audio, model: "gpt-transcribe"))
    // And changed back.
    await address.set(nil)
    _ = try await openAI.languageModel.complete(Self.prompt)

    #expect(
      server.requests.map(\.url.host) == [
        "api.openai.com", "collector.example.net", "collector.example.net", "api.openai.com",
      ]
    )
    #expect(
      server.requests.map { $0.header("Authorization") } == [
        "Bearer sk-openai", nil, nil, "Bearer sk-openai",
      ]
    )
    for request in server.requests where request.url.host == "collector.example.net" {
      #expect(!request.headers.values.contains { $0.contains("sk-openai") })
      #expect(!String(decoding: request.body, as: UTF8.self).contains("sk-openai"))
      #expect(!request.url.absoluteString.contains("sk-openai"))
    }
  }

  @Test func aKeySavedForACustomServerIsSentOnlyThere() async throws {
    let server = Server(Self.hello)
    let address = Address()
    await address.set("https://Gateway.Example.com/v1")
    let secrets = InMemorySecretStore(apiKey: "sk-gateway", host: "gateway.example.com")
    let openAI = server.openAI(secrets: secrets) { await address.text }

    _ = try await openAI.languageModel.complete(Self.prompt)
    #expect(server.requests.last?.header("Authorization") == "Bearer sk-gateway")

    // Another custom server, a look-alike host, and the same name on another level: no key.
    for other in [
      "http://localhost:11434", "https://gateway.example.com.evil.example/v1", "https://example.com/v1",
    ] {
      await address.set(other)
      _ = try await openAI.languageModel.complete(Self.prompt)
      #expect(server.requests.last?.url.host != "gateway.example.com")
      #expect(server.requests.last?.header("Authorization") == nil)
    }

    // The settings forget the custom server (a damaged settings file recovers to the defaults):
    // OpenAI gets nothing at all, because the only key there is belongs to another host.
    await address.set(nil)
    let before = server.requests.count
    let audio = try recordings.file()
    let chat = await wisperError { _ = try await openAI.languageModel.complete(Self.prompt) }
    let speech = await wisperError {
      _ = try await openAI.transcriber.transcribe(TranscriptionRequest(audio: audio, model: "gpt-transcribe"))
    }
    #expect(chat == .missingAPIKey)
    #expect(speech == .missingAPIKey)
    #expect(server.requests.count == before)
  }

  @Test func aCustomServerThatWantsAKeySaysSoWhenTheSavedKeyBelongsElsewhere() async throws {
    let server = Server(.error(401, "Missing bearer token."))
    let openAI = server.openAI(
      key: "sk-openai",
      baseURL: "https://gateway.example.com/v1",
      savedFor: "api.openai.com"
    )

    let error = await wisperError { _ = try await openAI.languageModel.complete(Self.prompt) }

    // Not "your key was not accepted": no key was sent.
    #expect(error == .missingAPIKey)
    #expect(server.requests.count == 1)
    #expect(server.requests.first?.header("Authorization") == nil)
    let message = try #require(error?.message(server: APIServer(address: "https://gateway.example.com/v1")))
    #expect(message == "gateway.example.com asked for an API key. Add the key for this server in Settings.")
  }

  @Test func aKeyBeingTriedOutGoesToTheServerTheSettingsName() async throws {
    let server = Server(.ok(#"{"object": "list", "data": []}"#))

    try await server.openAI(key: nil, baseURL: "https://gateway.example.com/v1").check(key: "sk-new")

    #expect(server.requests.map(\.url.absoluteString) == ["https://gateway.example.com/v1/models"])
    #expect(server.requests.first?.header("Authorization") == "Bearer sk-new")
  }

  // MARK: The key

  @Test func needsAKeyForOpenAIAndAsksNothingWithoutOne() async throws {
    for key in [nil, "", "  \n"] as [String?] {
      let server = Server(Self.hello)
      let openAI = server.openAI(secrets: FixedSecrets(key: key))
      let audio = try recordings.file()

      let chat = await wisperError { _ = try await openAI.languageModel.complete(Self.prompt) }
      let speech = await wisperError {
        _ = try await openAI.transcriber.transcribe(
          TranscriptionRequest(audio: audio, model: "gpt-transcribe")
        )
      }
      let check = await wisperError { try await openAI.check(key: key ?? "") }

      #expect(chat == .missingAPIKey)
      #expect(speech == .missingAPIKey)
      #expect(check == .missingAPIKey)
      #expect(server.requests.isEmpty)
    }
  }

  @Test func callsACustomServerWithoutAKey() async throws {
    let server = Server(Self.hello)

    let text = try await server.openAI(key: nil, baseURL: "http://localhost:11434").languageModel
      .complete(Self.prompt)

    #expect(text == "Hello.")
    let request = try #require(server.requests.first)
    #expect(request.header("Authorization") == nil)
  }

  @Test func sendsAStoredKeyToACustomServerToo() async throws {
    let server = Server(Self.hello)

    _ = try await server.openAI(key: " sk-proxy \n", baseURL: "https://gateway.example.com/v1").languageModel
      .complete(Self.prompt)

    // The stray space and line break from pasting are gone.
    #expect(server.requests.first?.header("Authorization") == "Bearer sk-proxy")
  }

  @Test func turnsDownAKeyThatCannotBeSent() async throws {
    let server = Server(Self.hello)

    let error = await wisperError {
      _ = try await server.openAI(key: "sk-abc\r\nX-Injected: yes").languageModel.complete(Self.prompt)
    }

    #expect(error == .invalidAPIKey)
    #expect(server.requests.isEmpty)
  }

  @Test func reportsAKeyThatCannotBeRead() async throws {
    let server = Server(Self.hello)

    let error = await wisperError {
      _ = try await server.openAI(
        secrets: FixedSecrets(failure: WisperError.storage("the keychain is locked"))
      )
      .languageModel.complete(Self.prompt)
    }

    #expect(error == .storage("the keychain is locked"))
    #expect(server.requests.isEmpty)
  }

  /// Hands out its key for OpenAI only.
  struct FixedSecrets: SecretStore {
    var key: String?
    var failure: WisperError?
    func apiKey(for host: String) async throws -> String? {
      if let failure { throw failure }
      return host == APIServer.openAIHost ? key : nil
    }
    func setAPIKey(_ key: String?, host: String) async throws {}
  }

  // MARK: Errors

  @Test func mapsARejectedKey() async throws {
    let server = Server(.error(401, "Incorrect API key provided: sk-test-key.", code: "invalid_api_key"))

    let error = await wisperError { _ = try await server.openAI().languageModel.complete(Self.prompt) }

    #expect(error == .invalidAPIKey)
    #expect(server.requests.count == 1)
  }

  @Test(arguments: [
    (400, "The model `m` does not exist."), (403, "Country, region, or territory not supported"),
    (404, "Not found."), (413, "Maximum content size limit exceeded."),
  ])
  func passesOnWhatTheServerSaid(status: Int, message: String) async throws {
    let server = Server(.error(status, message))

    let error = await wisperError { _ = try await server.openAI().languageModel.complete(Self.prompt) }

    #expect(error == .server(status: status, message: message))
    #expect(server.requests.count == 1)
  }

  @Test(arguments: [
    (#"{"error": "model 'llama' not found"}"#, "model 'llama' not found"),
    (#"{"message": "Bad\nrequest"}"#, "Bad request"),
    ("<html><body>502 Bad Gateway</body></html>", "The server gave no details."),
    ("", "The server gave no details."),
  ])
  func readsErrorsFromServersThatAreNotOpenAI(body: String, message: String) async throws {
    let server = Server(.reply(status: 404, body: body))

    let error = await wisperError { _ = try await server.openAI().languageModel.complete(Self.prompt) }

    #expect(error == .server(status: 404, message: message))
  }

  @Test(arguments: [
    (URLError.Code.notConnectedToInternet, "you are offline"),
    (.timedOut, "the request timed out"),
    (.cannotFindHost, "the server was not found"),
    (.cannotConnectToHost, "the server did not answer"),
    (.networkConnectionLost, "the connection was lost"),
    (.secureConnectionFailed, "a secure connection could not be made"),
  ])
  func mapsAConnectionFailure(code: URLError.Code, reason: String) async throws {
    let server = Server(.fail(code))

    let error = await wisperError { _ = try await server.openAI().languageModel.complete(Self.prompt) }

    #expect(error == .network(reason))
  }

  @Test func rejectsAnOKReplyItCannotRead() async throws {
    let server = Server(.ok("<html>Sign in to the hotel Wi-Fi</html>"))
    let audio = try recordings.file()

    let chat = await wisperError { _ = try await server.openAI().languageModel.complete(Self.prompt) }
    let speech = await wisperError {
      _ = try await server.openAI().transcriber.transcribe(
        TranscriptionRequest(audio: audio, model: "whisper-1")
      )
    }
    let check = await wisperError { try await server.openAI().check(key: "sk-test-key") }

    #expect(chat == .invalidResponse("the answer was missing"))
    #expect(speech == .invalidResponse("the transcript was missing"))
    #expect(check == .invalidResponse("the server did not answer like an OpenAI server"))
  }

  // MARK: The key stays secret

  @Test func neverPutsTheKeyInAnError() async throws {
    let key = "sk-proj-SECRET1234567890"
    let echo = "Bad request for Bearer \(key) (key \(key))"
    let answers: [Server.Answer] = [
      .error(400, echo), .error(401, echo), .error(403, echo), .error(429, echo, code: "insufficient_quota"),
      .error(429, echo), .error(500, echo), .reply(status: 502, body: echo), .ok(echo),
      .reply(status: 400, body: #"{"error": "\#(echo)"}"#), .fail(.timedOut), .fail(.badServerResponse),
      .fail(.userAuthenticationRequired),
    ]
    let audio = try recordings.file()

    for answer in answers {
      let server = Server(answer)
      let openAI = server.openAI(key: key, baseURL: "https://user:\(key)@gateway.example.com/v1")
      var errors: [any Error] = []
      do { _ = try await openAI.languageModel.complete(Self.prompt) } catch { errors.append(error) }
      do {
        _ = try await openAI.transcriber.transcribe(TranscriptionRequest(audio: audio, model: "whisper-1"))
      } catch { errors.append(error) }
      do { try await openAI.check(key: key) } catch { errors.append(error) }

      #expect(errors.count == 3)
      for error in errors {
        let texts = [error.localizedDescription, String(describing: error), String(reflecting: error)]
        #expect(!texts.contains { $0.contains(key) }, "\(texts)")
      }
      #expect(!server.requests.isEmpty)
    }
  }

  @Test func hidesAKeyThatSitsAcrossTheLengthLimit() async throws {
    let key = "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnop"
    // The key starts just before the 300th character, so a cut made first would split it.
    for lead in [270, 280, 290, 299, 300] {
      let filler = String(repeating: "x", count: lead)
      let server = Server(.error(400, "\(filler) bad key \(key) given"))

      let error = await wisperError {
        _ = try await server.openAI(key: key).languageModel.complete(Self.prompt)
      }

      guard case .server(400, let message) = error else {
        Issue.record("Expected the server's message, got \(String(describing: error))")
        continue
      }
      #expect(message.count <= 300)
      #expect(!message.contains("sk-proj"), "\(message.suffix(40))")
      #expect(!message.contains(key.prefix(12)))
    }
  }

  // MARK: Redirects

  @Test func doesNotFollowARedirectToAnotherHost() async throws {
    // Two real servers on this machine. The second one stands for a host nobody chose.
    let other = try LocalServer { _, _ in LocalServer.ok(#"{"text": "Stolen."}"#) }
    let first = try LocalServer { request, _ in
      LocalServer.redirect(to: "http://localhost:\(other.port)\(request.path)")
    }
    let openAI = OpenAI(
      secrets: InMemorySecretStore(apiKey: "sk-local", host: "127.0.0.1"),
      address: { "http://127.0.0.1:\(first.port)/v1" },
      session: URLSession(configuration: .ephemeral)
    )
    let audio = try recordings.file(bytes: Data("the audio".utf8))

    let speech = await wisperError {
      _ = try await openAI.transcriber.transcribe(TranscriptionRequest(audio: audio, model: "gpt-transcribe"))
    }
    let chat = await wisperError { _ = try await openAI.languageModel.complete(Self.prompt) }

    // The audio, the prompt and the key went to the server that was asked, and no further.
    #expect(other.requests.isEmpty)
    #expect(first.requests.map(\.path) == ["/v1/audio/transcriptions", "/v1/chat/completions"])
    #expect(first.requests.allSatisfy { $0.headers["authorization"] == "Bearer sk-local" })
    let expected = WisperError.server(
      status: 307,
      message:
        "The server tried to pass the request on to another address (localhost). Nothing was sent there."
    )
    #expect(speech == expected)
    #expect(chat == expected)
  }

  @Test func followsARedirectOnTheSameHost() async throws {
    let server = try LocalServer { request, port in
      request.path.hasPrefix("/moved")
        ? LocalServer.ok(#"{"choices": [{"message": {"role": "assistant", "content": "Hello."}}]}"#)
        : LocalServer.redirect(to: "http://127.0.0.1:\(port)/moved\(request.path)")
    }
    let openAI = OpenAI(
      secrets: InMemorySecretStore(apiKey: "sk-local", host: "127.0.0.1"),
      address: { "http://127.0.0.1:\(server.port)/v1" },
      session: URLSession(configuration: .ephemeral)
    )

    let text = try await openAI.languageModel.complete(Self.prompt)

    #expect(text == "Hello.")
    #expect(server.requests.map(\.path) == ["/v1/chat/completions", "/moved/v1/chat/completions"])
    // The question went along to the new place.
    #expect(server.requests.last?.body == server.requests.first?.body)
    #expect(server.requests.last?.body.isEmpty == false)
  }

  // MARK: Retries

  @Test(arguments: [
    Server.Answer.error(500, "The server had an error."),
    .error(503, "Overloaded.", code: "server_is_overloaded"),
    .reply(status: 502, body: "Bad gateway"), .error(429, "Rate limit reached for requests."),
    .fail(.networkConnectionLost), .fail(.timedOut), .fail(.notConnectedToInternet),
  ])
  func triesAgainAfterAPassingFailure(failure: Server.Answer) async throws {
    let server = Server(failure, failure, Self.hello)

    let text = try await server.openAI().languageModel.complete(Self.prompt)

    #expect(text == "Hello.")
    #expect(server.requests.count == 3)
    // Half a second, then a full one.
    #expect(server.pauses == [0.5, 1])
  }

  @Test func uploadsTheSameAudioAgainOnARetry() async throws {
    let server = Server(.fail(.networkConnectionLost), .ok(#"{"text": "Hello."}"#))
    let audio = try recordings.file(bytes: Data("the audio".utf8))

    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(audio: audio, model: "gpt-transcribe")
    )

    #expect(transcript.text == "Hello.")
    #expect(server.requests.map { $0.form.file?.text } == ["the audio", "the audio"])
  }

  @Test func givesUpAfterThreeTries() async throws {
    let cases: [(Server.Answer, WisperError)] = [
      (.error(500, "The server had an error."), .server(status: 500, message: "The server had an error.")),
      (.error(429, "Rate limit reached."), .rateLimited),
      (.fail(.networkConnectionLost), .network("the connection was lost")),
    ]
    for (failure, expected) in cases {
      let server = Server(failure)

      let error = await wisperError { _ = try await server.openAI().languageModel.complete(Self.prompt) }

      #expect(error == expected)
      #expect(server.requests.count == 3)
      #expect(server.pauses.count == 2)
    }
  }

  @Test func waitsAsLongAsTheServerAsks() async throws {
    let server = Server(
      .error(429, "Slow down.", headers: ["Retry-After": "3"]),
      .error(503, "Overloaded.", headers: ["retry-after-ms": "250"]),
      Self.hello
    )

    _ = try await server.openAI().languageModel.complete(Self.prompt)

    #expect(server.pauses == [3, 0.25])
  }

  @Test func doesNotKeepSomeoneWaitingWhenTheServerAsksForALongWait() async throws {
    let server = Server(.error(429, "Slow down.", headers: ["Retry-After": "120"]))

    let error = await wisperError { _ = try await server.openAI().languageModel.complete(Self.prompt) }

    #expect(error == .rateLimited)
    #expect(server.requests.count == 1)
    #expect(server.pauses.isEmpty)
  }

  @Test func doesNotTryAgainWhenTheAccountIsOutOfCredit() async throws {
    let message = "You exceeded your current quota, please check your plan and billing details."
    let server = Server(.error(429, message, code: "insufficient_quota"))

    let error = await wisperError { _ = try await server.openAI().languageModel.complete(Self.prompt) }

    // The person needs to hear it is about billing, not "try again in a moment".
    #expect(error == .server(status: 429, message: message))
    #expect(server.requests.count == 1)
  }

  @Test(arguments: [URLError.Code.secureConnectionFailed, .badURL, .userAuthenticationRequired])
  func doesNotTryAgainAfterAFailureThatWillNotPass(code: URLError.Code) async throws {
    let server = Server(.fail(code))

    _ = await wisperError { _ = try await server.openAI().languageModel.complete(Self.prompt) }

    #expect(server.requests.count == 1)
  }

  // MARK: Cancelling and timing out

  @Test func stopsWhenItsTaskIsCancelled() async throws {
    let server = Server(.hang)
    let openAI = server.openAI()
    let audio = try recordings.file()

    let chat = Task { try await openAI.languageModel.complete(Self.prompt) }
    let speech = Task {
      try await openAI.transcriber.transcribe(TranscriptionRequest(audio: audio, model: "gpt-transcribe"))
    }
    // Wait until both requests are with the server (two seconds at most, so a bug cannot hang the run).
    for _ in 0..<400 where server.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(server.requests.count == 2)
    chat.cancel()
    speech.cancel()

    await #expect(throws: CancellationError.self) { _ = try await chat.value }
    await #expect(throws: CancellationError.self) { _ = try await speech.value }
    #expect(server.requests.count == 2)
  }

  @Test func stopsRetryingWhenItsTaskIsCancelled() async throws {
    let server = Server(.fail(.networkConnectionLost))
    let reached = Signal()
    let openAI = OpenAI(
      secrets: InMemorySecretStore(apiKey: "sk-test-key"),
      address: { nil },
      session: server.session
    ) {
      _ in
      // The wait before the first retry: hold here until the task is cancelled.
      await reached.fire()
      try await Task.sleep(for: .seconds(60))
    }

    let task = Task { try await openAI.languageModel.complete(Self.prompt) }
    await reached.wait()
    task.cancel()

    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(server.requests.count == 1)
  }

  actor Signal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
      fired = true
      waiters.forEach { $0.resume() }
      waiters = []
    }

    func wait() async {
      if fired { return }
      await withCheckedContinuation { waiters.append($0) }
    }
  }

  @Test func givesUpWhenTheWholeCallTakesTooLong() async throws {
    let server = Server(.hang)

    let error = await wisperError {
      _ = try await server.client().send(budget: 0.05) { _ in
        Client.Call(method: "GET", path: "models", idle: 60)
      }
    }

    #expect(error == .network("the request timed out"))
    #expect(server.requests.count == 1)
  }

  // MARK: Checking a key

  @Test func checksAKeyByListingModels() async throws {
    let server = Server(.ok(#"{"object": "list", "data": [{"id": "gpt-6-luna", "object": "model"}]}"#))

    // The key being tried is the one sent, not the one already stored.
    try await server.openAI(key: "sk-stored").check(key: "sk-new")

    let request = try #require(server.requests.first)
    #expect(server.requests.count == 1)
    #expect(request.method == "GET")
    #expect(request.url.absoluteString == "https://api.openai.com/v1/models")
    #expect(request.header("Authorization") == "Bearer sk-new")
    #expect(request.body.isEmpty)
    #expect(request.timeout == 15)
  }

  @Test func reportsAKeyTheServerTurnsDown() async throws {
    let server = Server(.error(401, "Incorrect API key provided.", code: "invalid_api_key"))

    let error = await wisperError { try await server.openAI().check(key: "sk-wrong") }

    #expect(error == .invalidAPIKey)
  }

  @Test func reportsWhenTheServerCannotBeReachedForACheck() async throws {
    let server = Server(.fail(.notConnectedToInternet))

    let error = await wisperError { try await server.openAI().check(key: "sk-new") }

    #expect(error == .network("you are offline"))
  }

  @Test func acceptsAKeyThatWorksButMayNotListModels() async throws {
    let server = Server(
      .error(403, "You have insufficient permissions for this operation. Missing scopes: api.model.read.")
    )

    try await server.openAI().check(key: "sk-restricted")

    #expect(server.requests.count == 1)
  }

  @Test func checksACustomServerAtItsOwnAddress() async throws {
    let server = Server(.ok(#"{"object": "list", "data": []}"#))

    try await server.openAI(key: nil, baseURL: "http://localhost:11434").check(key: "")

    #expect(server.requests.first?.url.absoluteString == "http://localhost:11434/v1/models")
    #expect(server.requests.first?.header("Authorization") == nil)
  }
}
