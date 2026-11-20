import Foundation
import SpacesDomain

/// The user's Anthropic account, for Claude models.
///
/// Talks to Anthropic's own API at `https://api.anthropic.com/v1`, always: the custom server
/// address in Settings is for OpenAI-compatible servers and never applies here. The key is
/// the one saved for `api.anthropic.com`, read again for every request. Without one, every
/// call throws before anything is sent.
///
/// Anthropic turns no speech into text, so Claude only does the text work: tidying
/// dictations, following spoken commands and writing meeting notes.
///
/// Every call throws `SpacesError.anthropic`, or `CancellationError` when its task is cancelled.
public struct Anthropic: Sendable {
  private let client: Client

  /// - Parameter secrets: Where the key is read from, on every request.
  public init(secrets: any SecretStore) {
    client = Client(secrets: secrets, dialect: .anthropic) { APIServer.anthropic.root.absoluteString }
  }

  /// Answers prompts with the Claude model named in each request.
  public var languageModel: any LanguageModel { AnthropicLanguageModel(client: client) }

  /// Asks Anthropic whether `key` works, without storing it.
  ///
  /// Throws `SpacesError.anthropic(.invalidAPIKey)` when Anthropic turns the key down,
  /// `.anthropic(.missingAPIKey)` when `key` is empty, and `.anthropic(.network)` when
  /// Anthropic cannot be reached.
  public func check(key: String) async throws {
    try await Anthropic.worded {
      // Listing models is free and needs a working key.
      let reply = try await client.send(key: .given(key), budget: 20) { _ in
        Client.Call(method: "GET", path: "models", wait: 6)
      }
      // A sign-in page from a hotel network also answers "200 OK", so make sure this is Anthropic talking.
      guard (try? JSONSerialization.jsonObject(with: reply)) is [String: Any] else {
        throw SpacesError.invalidResponse("the server did not answer like Anthropic")
      }
    }
  }

  /// Runs `work` and words any `SpacesError` it throws for Anthropic.
  static func worded<T>(_ work: () async throws -> T) async throws -> T {
    do {
      return try await work()
    } catch let error as SpacesError {
      if case .anthropic = error { throw error }
      throw SpacesError.anthropic(error)
    }
  }
}

/// Sends each prompt to the company whose model it names: a Claude model (`claude-…`) to
/// Anthropic, any other to the OpenAI server the settings name.
public struct ModelRouter: LanguageModel {
  private let openAI: any LanguageModel
  private let anthropic: any LanguageModel

  public init(openAI: any LanguageModel, anthropic: any LanguageModel) {
    self.openAI = openAI
    self.anthropic = anthropic
  }

  public func complete(_ request: CompletionRequest) async throws -> String {
    try await (Settings.isClaude(request.model) ? anthropic : openAI).complete(request)
  }
}

/// The `LanguageModel` that asks Anthropic's `messages` endpoint.
///
/// No temperature is sent: the current API takes none. The effort the request asks for is
/// sent as `output_config.effort` (no effort at all becomes `low`, the least Claude takes),
/// and left out for older models that refuse it. A reply format becomes structured output,
/// so the answer always matches the schema. Models that support it get Anthropic's own
/// fallback: when the model declines, another Claude model answers in the same call.
struct AnthropicLanguageModel: LanguageModel {
  let client: Client

  /// Models that take `fallbacks`. Others are asked without.
  static let withFallbacks: Set<String> = [
    "claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5",
  ]
  static let fallbackBeta = "server-side-fallback-2026-07-01"

  func complete(_ request: CompletionRequest) async throws -> String {
    try await Anthropic.worded {
      let schema = try request.jsonSchema.map(AnthropicLanguageModel.schema)
      // The same allowance as for OpenAI: about half a minute for a dictation, more for long notes.
      let size = Double(request.system.count + request.user.count)
      let budget = min(300, 30 + size / 150 + (schema == nil ? 0 : 30))
      let quick = request.effort == CompletionRequest.Effort.none
      let wait = quick ? min(budget * 0.4, 4 + Double(request.user.count) / 250) : budget * 0.6
      let fallbacks = AnthropicLanguageModel.withFallbacks.contains(request.model.lowercased())

      let data = try await client.send(
        scope: request.model,
        optional: ["effort", "fallbacks"],
        budget: budget
      ) { leftOut in
        var body: [String: Any] = [
          "model": request.model,
          "max_tokens": 16_000,
          "messages": [["role": "user", "content": request.user]],
        ]
        if !request.system.isEmpty { body["system"] = request.system }
        var output: [String: Any] = [:]
        if let effort = request.effort, !leftOut.contains("effort") {
          output["effort"] = effort == .none ? "low" : effort.rawValue
        }
        if let schema { output["format"] = ["type": "json_schema", "schema": schema.value] }
        if !output.isEmpty { body["output_config"] = output }
        var headers: [String: String] = [:]
        if fallbacks, !leftOut.contains("fallbacks") {
          body["fallbacks"] = "default"
          headers["anthropic-beta"] = AnthropicLanguageModel.fallbackBeta
        }
        guard let json = try? JSONSerialization.data(withJSONObject: body) else {
          throw SpacesError.invalidResponse("the request could not be written")
        }
        return Client.Call(method: "POST", path: "messages", body: .json(json), wait: wait, headers: headers)
      }
      return try AnthropicLanguageModel.text(in: data)
    }
  }

  /// A JSON value that may cross into the task that builds the request.
  private struct Schema: @unchecked Sendable {
    let value: [String: Any]
  }

  private static func schema(_ text: String) throws -> Schema {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
      throw SpacesError.invalidResponse("the reply format the app asked for is not valid JSON")
    }
    // Anthropic reads the schema itself; a title is only a name for OpenAI.
    var schema = object
    schema["title"] = nil
    return Schema(value: schema)
  }

  private static func text(in data: Data) throws -> String {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let content = json["content"] as? [[String: Any]]
    else { throw SpacesError.invalidResponse("the answer was missing") }
    switch json["stop_reason"] as? String {
    case "refusal": throw SpacesError.invalidResponse("the model declined to answer")
    case "max_tokens": throw SpacesError.invalidResponse("the answer was cut off because it was too long")
    default: break
    }
    // Thinking and fallback blocks carry no answer: only the text counts.
    let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
      .joined()
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SpacesError.invalidResponse("the answer was empty") }
    return trimmed
  }
}
