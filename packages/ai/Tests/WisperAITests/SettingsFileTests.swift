import Foundation
import Testing
import WisperDomain
import WisperStore

@testable import WisperAI

/// The real settings file, the real key rule and the request code together: what leaves this
/// device when `settings.json` is changed or damaged behind the app's back.
@Suite struct SettingsFileTests {
  let recordings: Recordings
  let root: URL

  init() throws {
    recordings = try Recordings()
    root = recordings.folder.appendingPathComponent("data", isDirectory: true)
  }

  /// Wired the way the apps wire it: the address is read from the settings file for every request.
  private func openAI(_ server: Server, library: FileLibrary, secrets: InMemorySecretStore) -> OpenAI {
    server.openAI(secrets: secrets) { try await library.settings().apiBaseURL }
  }

  private func dictate(with openAI: OpenAI) async throws -> WisperError? {
    let audio = try recordings.file()
    return await wisperError {
      _ = try await openAI.transcriber.transcribe(TranscriptionRequest(audio: audio, model: "gpt-transcribe"))
    }
  }

  @Test func aDamagedSettingsFileNeverSendsAudioOrTheKeyToOpenAI() async throws {
    let server = Server(.ok(#"{"text": "Hello."}"#))
    let library = FileLibrary(root: root)
    try await library.updateSettings { $0.apiBaseURL = "http://127.0.0.1:8080/v1" }
    // The key was saved while the custom server was set, so it belongs to that server.
    let secrets = InMemorySecretStore(apiKey: "sk-local", host: "127.0.0.1")
    let openAI = openAI(server, library: library, secrets: secrets)

    let audio = try recordings.file()
    _ = try await openAI.transcriber.transcribe(TranscriptionRequest(audio: audio, model: "gpt-transcribe"))
    #expect(server.requests.map(\.url.host) == ["127.0.0.1"])
    #expect(server.requests.first?.header("Authorization") == "Bearer sk-local")

    // The file is damaged (a crash, a bad hand edit). The library recovers to the defaults,
    // which have no custom server.
    try Data("{{{{ broken".utf8).write(to: root.appendingPathComponent("settings.json"))
    #expect(try await library.settings().apiBaseURL == nil)

    // A fresh start, as after the app is opened again.
    for client in [openAI, self.openAI(server, library: FileLibrary(root: root), secrets: secrets)] {
      #expect(try await dictate(with: client) == .missingAPIKey)
      let chat = await wisperError {
        _ = try await client.languageModel.complete(CompletionRequest(model: "m", system: "", user: "hi"))
      }
      #expect(chat == .missingAPIKey)
    }
    // Nothing went to OpenAI, or anywhere else.
    #expect(server.requests.count == 1)
  }

  @Test func anAddressEditedIntoSomethingUnusableSendsNothing() async throws {
    let server = Server(.ok(#"{"text": "Hello."}"#))
    let library = FileLibrary(root: root)
    // Typed by hand, without "http://". A key for OpenAI is saved, so a fallback would work.
    try await library.updateSettings { $0.apiBaseURL = "127.0.0.1:63570/v1" }
    let openAI = openAI(server, library: library, secrets: InMemorySecretStore(apiKey: "sk-openai"))

    #expect(try await dictate(with: openAI) == .invalidServerAddress)
    #expect(server.requests.isEmpty)

    // Put right, it works, and the OpenAI key still does not go to the local server.
    try await library.updateSettings { $0.apiBaseURL = "http://127.0.0.1:63570/v1" }
    let audio = try recordings.file()
    _ = try await openAI.transcriber.transcribe(TranscriptionRequest(audio: audio, model: "gpt-transcribe"))
    #expect(server.requests.map(\.url.host) == ["127.0.0.1"])
    #expect(server.requests.first?.header("Authorization") == nil)
  }

  @Test func aSettingsFileChangedByHandToAnotherServerGetsNoKey() async throws {
    let server = Server(.ok(#"{"text": "Hello."}"#))
    let library = FileLibrary(root: root)
    try await library.updateSettings { $0.userName = "Alex" }
    let openAI = openAI(server, library: library, secrets: InMemorySecretStore(apiKey: "sk-openai"))
    let audio = try recordings.file()
    let request = TranscriptionRequest(audio: audio, model: "gpt-transcribe")

    _ = try await openAI.transcriber.transcribe(request)
    // One line added to the plain file by something other than the app.
    let file = root.appendingPathComponent("settings.json")
    let text = try String(contentsOf: file, encoding: .utf8)
      .replacingOccurrences(of: "{\n", with: "{\n  \"apiBaseURL\" : \"https://collector.example.net/v1\",\n")
    try Data(text.utf8).write(to: file)
    _ = try await openAI.transcriber.transcribe(request)

    #expect(server.requests.map(\.url.host) == ["api.openai.com", "collector.example.net"])
    #expect(server.requests.map { $0.header("Authorization") } == ["Bearer sk-openai", nil])
  }
}
