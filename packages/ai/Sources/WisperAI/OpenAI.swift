import Foundation
import WisperDomain

/// The user's OpenAI account, as the app sees it.
///
/// Talks to the OpenAI HTTP API, or to any server that speaks the same API.
/// Nothing is cached between calls: the key and the server address are read
/// again for every request, so a change in Settings takes effect at once.
///
/// **The server address.** `APIServer` holds the rule. In short: no address means OpenAI; a
/// custom `http://` or `https://` address is taken as the folder that holds the API, and the
/// endpoint is added to it. An address that is set but is not a usable web address makes
/// every call throw `WisperError.invalidServerAddress` before anything is sent. It never
/// falls back to OpenAI: the person chose another server.
///
/// **The key.** A saved key belongs to the server it was saved for, and each request asks for
/// the key of the server it is about to call. A key saved for another server is not sent.
/// OpenAI itself needs a key, so without one the calls throw `WisperError.missingAPIKey`
/// before anything is sent. Any other server is called without a key when none is saved for
/// it, because local servers need none.
///
/// **Redirects.** A request follows a redirect only on the same host. Audio, text and the key
/// are never passed on to a host the settings do not name.
///
/// Every call throws `WisperError`, or `CancellationError` when its task is
/// cancelled. Short network drops, rate limits and server hiccups are retried
/// a couple of times before the call gives up.
public struct OpenAI: Sendable {
  private let client: Client

  /// - Parameters:
  ///   - secrets: Where the API key is read from, on every request.
  ///   - address: Returns `Settings.apiBaseURL` as it is stored: the text of the custom server
  ///     address, or `nil` for OpenAI itself. Read on every request. Pass the text untouched,
  ///     so an address that cannot be used is reported instead of ignored. An error it throws
  ///     (the settings could not be read) fails the request: nothing is sent.
  ///   - session: The session that carries the requests.
  public init(
    secrets: any SecretStore,
    address: @escaping @Sendable () async throws -> String?,
    session: URLSession = .shared
  ) {
    self.init(secrets: secrets, address: address, session: session) { seconds in
      try await Task.sleep(for: .seconds(seconds))
    }
  }

  /// The earlier form of `init(secrets:address:session:)`, which takes the address already
  /// made into a URL. Prefer the other one: text that could not be made into a URL arrives
  /// here as `nil`, which means OpenAI, so that mistake cannot be reported.
  public init(
    secrets: any SecretStore,
    baseURL: @escaping @Sendable () async -> URL? = { nil },
    session: URLSession = .shared
  ) {
    self.init(secrets: secrets, address: { await baseURL()?.absoluteString }, session: session)
  }

  /// `pause` waits between retries. Tests pass one that returns at once.
  init(
    secrets: any SecretStore,
    address: @escaping @Sendable () async throws -> String?,
    session: URLSession,
    pause: @escaping @Sendable (TimeInterval) async throws -> Void
  ) {
    client = Client(secrets: secrets, address: address, session: session, pause: pause)
  }

  /// Turns audio files into text with the model named in each request.
  public var transcriber: any Transcriber { OpenAITranscriber(client: client) }

  /// Answers prompts with the model named in each request.
  public var languageModel: any LanguageModel { OpenAILanguageModel(client: client) }

  /// Asks the server whether `key` works, without storing it.
  ///
  /// Throws `WisperError.invalidAPIKey` when the server turns the key down,
  /// `.missingAPIKey` when `key` is empty and the server is OpenAI, and
  /// `.network` when the server cannot be reached.
  public func check(key: String) async throws {
    // Listing models is the cheapest call that needs a working key.
    let reply: Data
    do {
      reply = try await client.send(key: .given(key), budget: 20) { _ in
        Client.Call(method: "GET", path: "models", idle: 15)
      }
    } catch WisperError.server(status: 403, let message)
      where message.localizedCaseInsensitiveContains("missing scopes")
    {
      // OpenAI lets people make keys that may transcribe and chat but not list models.
      // Such a key was recognised (a bad one gets 401), so it works for what the app does.
      return
    }
    // A sign-in page from a hotel network also answers "200 OK", so make sure this is the API talking.
    guard (try? JSONSerialization.jsonObject(with: reply)) is [String: Any] else {
      throw WisperError.invalidResponse("the server did not answer like an OpenAI server")
    }
  }
}
