import Foundation
import WisperDomain

/// The user's OpenAI account, as the app sees it.
///
/// Talks to the OpenAI HTTP API, or to any server that speaks the same API.
/// Nothing is cached between calls: the key and the server address are read
/// again for every request, so a change in Settings takes effect at once.
///
/// **The server address.** A custom address is taken as the folder that holds
/// the API, and the endpoint is added to it: `https://example.com/api/v1`
/// becomes `https://example.com/api/v1/chat/completions`. A trailing slash
/// makes no difference, and anything after a `?` is kept. The one exception:
/// an address with no path at all (`http://localhost:11434`) gets `/v1` added,
/// because that is where every compatible server keeps its API. An address
/// that is not `http` or `https` is ignored and OpenAI is used.
///
/// **The key.** OpenAI itself needs a key, so without one the calls throw
/// `WisperError.missingAPIKey` before anything is sent. Any other server is
/// called without a key when none is stored, because local servers need none.
///
/// Every call throws `WisperError`, or `CancellationError` when its task is
/// cancelled. Short network drops, rate limits and server hiccups are retried
/// a couple of times before the call gives up.
public struct OpenAI: Sendable {
  private let client: Client

  /// - Parameters:
  ///   - secrets: Where the API key is read from, on every request.
  ///   - baseURL: Returns the user's custom server address, or `nil` for
  ///     `https://api.openai.com/v1`. Read on every request.
  ///   - session: The session that carries the requests.
  public init(
    secrets: any SecretStore,
    baseURL: @escaping @Sendable () async -> URL? = { nil },
    session: URLSession = .shared
  ) {
    self.init(secrets: secrets, baseURL: baseURL, session: session) { seconds in
      try await Task.sleep(for: .seconds(seconds))
    }
  }

  /// `pause` waits between retries. Tests pass one that returns at once.
  init(
    secrets: any SecretStore,
    baseURL: @escaping @Sendable () async -> URL?,
    session: URLSession,
    pause: @escaping @Sendable (TimeInterval) async throws -> Void
  ) {
    client = Client(secrets: secrets, baseURL: baseURL, session: session, pause: pause)
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
