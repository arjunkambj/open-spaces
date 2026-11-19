import Foundation
import WisperDomain

/// The `LanguageModel` that asks `chat/completions`.
///
/// Chat completions is used rather than OpenAI's newer endpoint because every
/// OpenAI-compatible server speaks it. The instructions go in a `system`
/// message for the same reason: OpenAI's newer models read it as their
/// `developer` message, and other servers know no other name.
///
/// `temperature` and `reasoning_effort` are sent only as long as the model takes them: some
/// models refuse a temperature, and some refuse the lowest effort.
/// When the server refuses it, the request is sent once more without it, and later requests
/// to that model leave it out from the start.
struct OpenAILanguageModel: LanguageModel {
  let client: Client

  func complete(_ request: CompletionRequest) async throws -> String {
    let format = try request.jsonSchema.map(OpenAILanguageModel.format)
    // Cleaning up a dictation should give up after about half a minute. Notes from a long
    // meeting get more time, in step with how much there is to read.
    let size = Double(request.system.count + request.user.count)
    let budget = min(300, 30 + size / 150 + (format == nil ? 0 : 30))

    let data = try await client.send(
      scope: request.model,
      optional: ["temperature", "reasoning_effort"],
      budget: budget
    ) { leftOut in
      var messages: [[String: String]] = []
      if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
      messages.append(["role": "user", "content": request.user])
      var body: [String: Any] = ["model": request.model, "messages": messages]
      if let temperature = request.temperature, !leftOut.contains("temperature") {
        body["temperature"] = temperature
      }
      if let effort = request.effort, !leftOut.contains("reasoning_effort") {
        body["reasoning_effort"] = effort.rawValue
      }
      if let format { body["response_format"] = format.value }
      guard let json = try? JSONSerialization.data(withJSONObject: body) else {
        throw WisperError.invalidResponse("the request could not be written")
      }
      // Nothing arrives until the whole answer is ready, so silence on the line is normal.
      return Client.Call(method: "POST", path: "chat/completions", body: .json(json), idle: budget)
    }

    let text = try OpenAILanguageModel.text(in: data)
    return format == nil ? text : try OpenAILanguageModel.json(in: text)
  }

  /// A JSON value that may cross into the task that builds the request.
  private struct Format: @unchecked Sendable {
    let value: [String: Any]
  }

  /// Structured outputs: with `strict` the reply always matches the schema.
  private static func format(_ schema: String) throws -> Format {
    guard let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any] else {
      throw WisperError.invalidResponse("the reply format the app asked for is not valid JSON")
    }
    // The API wants a name: letters, digits, dashes and underscores, at most 64.
    let title = (object["title"] as? String ?? "").filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    return Format(value: [
      "type": "json_schema",
      "json_schema": [
        "name": title.isEmpty ? "reply" : String(title.prefix(64)), "strict": true, "schema": object,
      ],
    ])
  }

  private static func text(in data: Data) throws -> String {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choice = (json["choices"] as? [[String: Any]])?.first,
      let message = choice["message"] as? [String: Any]
    else { throw WisperError.invalidResponse("the answer was missing") }

    var text: String?
    if let content = message["content"] as? String {
      text = content
    } else if let parts = message["content"] as? [[String: Any]] {
      // Some servers send the answer in pieces.
      text = parts.compactMap { $0["text"] as? String }.joined()
    }
    if let refusal = message["refusal"] as? String, !refusal.isEmpty, (text ?? "").isEmpty {
      throw WisperError.invalidResponse("the model declined to answer")
    }
    switch choice["finish_reason"] as? String {
    case "length": throw WisperError.invalidResponse("the answer was cut off because it was too long")
    case "content_filter": throw WisperError.invalidResponse("the answer was held back by a content filter")
    default: break
    }
    guard let text else { throw WisperError.invalidResponse("the answer was empty") }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Makes sure `text` is one JSON object. Local models like to wrap it in a code fence or a
  /// sentence, so the object is cut out of whatever surrounds it.
  private static func json(in text: String) throws -> String {
    func isObject(_ candidate: Substring) -> Bool {
      (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) is [String: Any]
    }
    if isObject(text[...]) { return text }
    if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
      isObject(text[start...end])
    {
      return String(text[start...end])
    }
    throw WisperError.invalidResponse("the answer was not in the format the app asked for")
  }
}
