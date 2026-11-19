import Foundation
import Testing
import WisperDomain

@testable import WisperAI

@Suite struct LanguageModelTests {
  /// A chat reply the way OpenAI writes them.
  static func reply(_ content: String?, finish: String = "stop", refusal: String? = nil) -> Server.Answer {
    let message: [String: Any] = [
      "role": "assistant", "content": content ?? NSNull(), "refusal": refusal ?? NSNull(),
    ]
    let body: [String: Any] = [
      "id": "chatcmpl-1", "object": "chat.completion",
      "choices": [["index": 0, "message": message, "finish_reason": finish]],
    ]
    return .ok(String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self))
  }

  // MARK: Request shape

  @Test func sendsTheInstructionsAndThePrompt() async throws {
    let server = Server(Self.reply("  Hello, world.\n"))

    let text = try await server.openAI().languageModel.complete(
      CompletionRequest(model: "gpt-6-luna", system: "Fix the punctuation.", user: "hello world")
    )

    #expect(text == "Hello, world.")
    let request = try #require(server.requests.first)
    #expect(server.requests.count == 1)
    #expect(request.method == "POST")
    #expect(request.url.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(request.header("Authorization") == "Bearer sk-test-key")
    #expect(request.header("Content-Type") == "application/json")
    #expect(Set(request.json.keys) == ["model", "messages"])
    #expect(request.json["model"] as? String == "gpt-6-luna")
    #expect(
      request.json["messages"] as? [[String: String]] == [
        ["role": "system", "content": "Fix the punctuation."], ["role": "user", "content": "hello world"],
      ]
    )
    // Tidying a sentence should give up in about half a minute.
    #expect((30...31).contains(request.timeout))
  }

  @Test func sendsTheEffortOnlyWhenOneIsSet() async throws {
    let server = Server(Self.reply("ok"))
    let model = server.openAI().languageModel

    _ = try await model.complete(
      CompletionRequest(model: "m", system: "", user: "hi", effort: CompletionRequest.Effort.none)
    )
    _ = try await model.complete(CompletionRequest(model: "m", system: "", user: "hi"))

    #expect(server.requests[0].json["reasoning_effort"] as? String == "none")
    #expect(server.requests[1].json["reasoning_effort"] == nil)
  }

  @Test func sendsTheTemperatureOnlyWhenOneIsSet() async throws {
    let server = Server(Self.reply("ok"))
    let model = server.openAI().languageModel

    _ = try await model.complete(CompletionRequest(model: "m", system: "", user: "hi", temperature: 0.2))
    _ = try await model.complete(CompletionRequest(model: "m", system: "", user: "hi"))

    #expect(server.requests[0].json["temperature"] as? Double == 0.2)
    #expect(server.requests[1].json["temperature"] == nil)
    // No instructions, no empty message.
    #expect(
      server.requests[0].json["messages"] as? [[String: String]] == [["role": "user", "content": "hi"]]
    )
  }

  @Test func givesLongPromptsMoreTime() async throws {
    let server = Server(Self.reply("ok"))

    _ = try await server.openAI().languageModel.complete(
      CompletionRequest(model: "m", system: "Write notes.", user: String(repeating: "word ", count: 6_000))
    )

    #expect(try #require(server.requests.first).timeout > 200)
  }

  // MARK: Structured output

  static let notesSchema = """
    {"type": "object", "properties": {"summary": {"type": "string"},
     "actions": {"type": "array", "items": {"type": "string"}}},
     "required": ["summary", "actions"], "additionalProperties": false}
    """

  @Test func asksForAReplyThatMatchesTheSchema() async throws {
    let server = Server(Self.reply(#"{"summary": "Launch on the 14th.", "actions": ["Call Sam"]}"#))

    let text = try await server.openAI().languageModel.complete(
      CompletionRequest(model: "gpt-6-luna", system: "Write notes.", user: "…", jsonSchema: Self.notesSchema)
    )

    // The JSON comes back as it was sent, ready to decode.
    struct Notes: Decodable, Equatable {
      var summary: String
      var actions: [String]
    }
    #expect(
      try JSONDecoder().decode(Notes.self, from: Data(text.utf8))
        == Notes(summary: "Launch on the 14th.", actions: ["Call Sam"])
    )
    let request = try #require(server.requests.first)
    let format = try #require(request.json["response_format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")
    let wrapper = try #require(format["json_schema"] as? [String: Any])
    #expect(wrapper["name"] as? String == "reply")
    #expect(wrapper["strict"] as? Bool == true)
    let sent = try #require(wrapper["schema"] as? NSDictionary)
    let asked = try JSONSerialization.jsonObject(with: Data(Self.notesSchema.utf8)) as? NSDictionary
    #expect(sent == asked)
  }

  @Test func cutsTheJSONOutOfAChattyReply() async throws {
    let server = Server(
      Self.reply("Here you go:\n```json\n{\"summary\": \"Short.\", \"actions\": []}\n```\nAnything else?")
    )

    let text = try await server.openAI(key: nil, baseURL: "http://localhost:11434").languageModel.complete(
      CompletionRequest(model: "llama", system: "", user: "…", jsonSchema: Self.notesSchema)
    )

    #expect(text == #"{"summary": "Short.", "actions": []}"#)
  }

  @Test func rejectsAReplyThatIsNotTheJSONAskedFor() async throws {
    let server = Server(Self.reply("I could not find any action items."))

    let error = await wisperError {
      _ = try await server.openAI().languageModel.complete(
        CompletionRequest(model: "m", system: "", user: "…", jsonSchema: Self.notesSchema)
      )
    }

    #expect(error == .invalidResponse("the answer was not in the format the app asked for"))
  }

  @Test func rejectsASchemaThatIsNotJSONBeforeSendingAnything() async throws {
    let server = Server(Self.reply("{}"))

    let error = await wisperError {
      _ = try await server.openAI().languageModel.complete(
        CompletionRequest(model: "m", system: "", user: "…", jsonSchema: "not json")
      )
    }

    #expect(error == .invalidResponse("the reply format the app asked for is not valid JSON"))
    #expect(server.requests.isEmpty)
  }

  // MARK: The temperature fallback

  @Test func sendsAgainWithoutTheTemperatureWhenTheModelRefusesIt() async throws {
    let server = Server { request, _ in
      request.json["temperature"] == nil
        ? Self.reply("Done.")
        : .error(
          400,
          "Unsupported value: 'temperature' does not support 0.2 with this model.",
          param: "temperature",
          code: "unsupported_value"
        )
    }
    let model = server.openAI().languageModel
    let request = CompletionRequest(model: "gpt-6.2-sol", system: "", user: "hi", temperature: 0.2)

    #expect(try await model.complete(request) == "Done.")
    #expect(server.requests.map { $0.json["temperature"] as? Double } == [0.2, nil])
    #expect(server.pauses.isEmpty)

    // Remembered for this model, so the next request is not sent twice…
    #expect(try await model.complete(request) == "Done.")
    #expect(server.requests.count == 3)
    #expect(server.requests[2].json["temperature"] == nil)

    // …while another model still gets its temperature.
    _ = try? await model.complete(CompletionRequest(model: "other", system: "", user: "hi", temperature: 0.7))
    #expect(server.requests[3].json["temperature"] as? Double == 0.7)
  }

  @Test func understandsARefusalWrittenOnlyInWords() async throws {
    let server = Server { request, _ in
      request.json["temperature"] == nil
        ? Self.reply("Done.")
        : .reply(status: 400, body: #"{"error": "Unrecognized request argument supplied: temperature"}"#)
    }

    let text = try await server.openAI(key: nil, baseURL: "http://localhost:1234/v1").languageModel.complete(
      CompletionRequest(model: "local", system: "", user: "hi", temperature: 0)
    )

    #expect(text == "Done.")
    #expect(server.requests.count == 2)
  }

  @Test func doesNotSendAgainForAnyOtherBadRequest() async throws {
    let server = Server(
      .error(400, "The model `gpt-9` does not exist.", param: "model", code: "model_not_found")
    )

    let error = await wisperError {
      _ = try await server.openAI().languageModel.complete(
        CompletionRequest(model: "gpt-9", system: "", user: "hi", temperature: 0.2)
      )
    }

    #expect(error == .server(status: 400, message: "The model `gpt-9` does not exist."))
    #expect(server.requests.count == 1)
  }

  @Test func givesUpWhenTheRequestIsStillRefusedWithoutTheTemperature() async throws {
    let server = Server(.error(400, "Unsupported parameter: 'temperature'.", param: "temperature"))

    let error = await wisperError {
      _ = try await server.openAI().languageModel.complete(
        CompletionRequest(model: "m", system: "", user: "hi", temperature: 0.2)
      )
    }

    #expect(error == .server(status: 400, message: "Unsupported parameter: 'temperature'."))
    #expect(server.requests.count == 2)
  }

  // MARK: Replies that hold no answer

  @Test func reportsARefusal() async throws {
    let server = Server(Self.reply(nil, refusal: "I can't help with that."))
    let error = await wisperError {
      _ = try await server.openAI().languageModel.complete(
        CompletionRequest(model: "m", system: "", user: "hi")
      )
    }
    #expect(error == .invalidResponse("the model declined to answer"))
  }

  @Test func reportsAnAnswerThatWasCutOff() async throws {
    let server = Server(Self.reply("Half an ans", finish: "length"))
    let error = await wisperError {
      _ = try await server.openAI().languageModel.complete(
        CompletionRequest(model: "m", system: "", user: "hi")
      )
    }
    #expect(error == .invalidResponse("the answer was cut off because it was too long"))
  }

  @Test(arguments: [
    "not json at all", "{}", #"{"choices": []}"#, #"{"choices": [{"message": {"content": null}}]}"#,
  ])
  func rejectsAReplyItCannotRead(body: String) async throws {
    let server = Server(.ok(body))
    let error = await wisperError {
      _ = try await server.openAI().languageModel.complete(
        CompletionRequest(model: "m", system: "", user: "hi")
      )
    }
    guard case .invalidResponse = error else {
      Issue.record("Expected .invalidResponse, got \(String(describing: error))")
      return
    }
  }

  @Test func acceptsAnEmptyAnswerAndAnAnswerInPieces() async throws {
    let empty = Server(Self.reply(""))
    #expect(
      try await empty.openAI().languageModel.complete(CompletionRequest(model: "m", system: "", user: "hi"))
        == ""
    )

    let pieces = Server(
      .ok(
        #"{"choices": [{"message": {"content": [{"type": "text", "text": "Hello, "}, {"text": "world."}]}}]}"#
      )
    )
    #expect(
      try await pieces.openAI().languageModel.complete(CompletionRequest(model: "m", system: "", user: "hi"))
        == "Hello, world."
    )
  }
}
