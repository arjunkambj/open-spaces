import Foundation
import WisperDomain

/// Meetings as MCP resources: each one is a Markdown document at
/// `openwisper://meetings/<id>`, the same address that opens it in the app.
enum Resources {
  static let pageSize = 100

  static let template: JSONValue = [
    "uriTemplate": "\(WisperLink.scheme)://meetings/{id}",
    "name": "meeting",
    "title": "Meeting",
    "description": .string(
      "One meeting as Markdown: summary, key points, decisions, action items, the user's notes and the "
        + "transcript. {id} is a meeting ID, the start of one, or \"latest\"."
    ),
    "mimeType": "text/markdown",
  ]

  /// The meeting ID (or "latest") inside a meeting address, or `nil` for any other address.
  static func meetingReference(in uri: String) -> String? {
    let prefix = "\(WisperLink.scheme)://meetings/"
    guard uri.lowercased().hasPrefix(prefix) else { return nil }
    let reference = String(uri.dropFirst(prefix.count))
    return reference.isEmpty || reference.contains("/") ? nil : reference
  }

  static func meeting(_ box: Toolbox, uri: String) async -> Meeting? {
    guard let reference = meetingReference(in: uri) else { return nil }
    return try? await box.meeting(reference)
  }

  /// What the resource list shows, in a form that is cheap to compare.
  static func fingerprint(_ box: Toolbox) async -> [String] {
    ((try? await box.library.meetings()) ?? []).map {
      "\($0.id.uuidString) \($0.status.rawValue) \($0.title)"
    }
  }

  static func list(_ box: Toolbox, cursor: String?) async throws -> JSONObject {
    var offset = 0
    if let cursor {
      guard let given = Int(cursor), given > 0 else {
        throw RPCError.invalidParams("Invalid params: unknown cursor.")
      }
      offset = given
    }
    let all = try await box.library.meetings()
    guard offset == 0 || offset < all.count else {
      throw RPCError.invalidParams("Invalid params: unknown cursor.")
    }
    let page = all.dropFirst(offset).prefix(pageSize)
    var result: JSONObject = [
      "resources": .array(
        page.map { meeting in
          var about = ["\(box.friendly(meeting.startedAt))", "\(Toolbox.minutes(meeting)) min"]
          if meeting.status != .ready { about.append(meeting.status.rawValue) }
          if let summary = meeting.notes?.summary, !summary.isEmpty {
            about.append(Toolbox.clipped(summary, to: 160))
          }
          return [
            "uri": .string(WisperLink.showMeeting(meeting.id).url.absoluteString),
            "name": .string(meeting.title),
            "title": .string(meeting.title),
            "description": .string(about.joined(separator: " · ")),
            "mimeType": "text/markdown",
            "annotations": ["lastModified": .string(box.iso(meeting.endedAt ?? meeting.startedAt))],
          ]
        }
      )
    ]
    if offset + page.count < all.count { result["nextCursor"] = .string(String(offset + page.count)) }
    return result
  }

  static func read(_ box: Toolbox, uri: String) async throws -> JSONObject {
    guard let meeting = await meeting(box, uri: uri) else {
      throw RPCError.invalidParams("Resource not found", data: ["uri": .string(uri)])
    }
    return [
      "contents": [
        [
          "uri": .string(uri),
          "mimeType": "text/markdown",
          "text": .string(meeting.markdown(timeZone: box.environment.timeZone)),
        ]
      ]
    ]
  }
}

/// Ready-made requests a person can pick from their MCP client's menu.
struct Prompt: Sendable {
  struct Argument: Sendable {
    var name: String
    var help: String
  }

  var name: String
  var title: String
  var description: String
  var arguments: [Argument] = []
  /// Returns the text of the request, and a meeting to attach to it when there is one.
  var build: @Sendable (Toolbox, [String: String]) async throws -> (text: String, attach: Meeting?)

  var definition: JSONValue {
    [
      "name": .string(name),
      "title": .string(title),
      "description": .string(description),
      "arguments": .array(
        arguments.map { ["name": .string($0.name), "description": .string($0.help), "required": false] }
      ),
    ]
  }
}

enum Prompts {
  private static let meetingArgument = Prompt.Argument(
    name: "meeting",
    help: "A meeting ID, the start of one, or \"latest\". Left out, the most recent meeting is used."
  )

  static let all: [Prompt] = [
    Prompt(
      name: "summarise_meeting",
      title: "Summarise a meeting",
      description:
        "Summarise a meeting (the most recent one unless you name another): outcome, decisions, to-dos.",
      arguments: [meetingArgument],
      build: { box, arguments in
        let meeting = try await box.meeting(arguments["meeting"] ?? "latest")
        return (
          "Summarise my meeting \"\(meeting.title)\" from \(box.friendly(meeting.startedAt)). The full "
            + "meeting is attached. Give me, in this order: the outcome in two or three sentences, the "
            + "decisions that were made, and the action items with who owns each one. Keep it short and "
            + "use plain words. If something important was said but is missing from the notes, add it.",
          meeting
        )
      }
    ),
    Prompt(
      name: "open_action_items",
      title: "What do I still have to do?",
      description: "Go through the open action items from all meetings and say what to do first.",
      arguments: [Prompt.Argument(name: "owner", help: "Only items owned by this person.")],
      build: { _, arguments in
        let owner = arguments["owner"].map { " with the owner \"\($0)\"" } ?? ""
        return (
          "Call the actions_list tool\(owner) to get my open action items from Open Wisper. Group them by "
            + "meeting, oldest meeting first, and say which ones look most urgent and why. Then ask me "
            + "which ones are finished and tick those off with actions_set_done.",
          nil
        )
      }
    ),
    Prompt(
      name: "follow_up_email",
      title: "Draft a follow-up email",
      description:
        "Draft a short follow-up email for a meeting (the most recent one unless you name another).",
      arguments: [meetingArgument],
      build: { box, arguments in
        let meeting = try await box.meeting(arguments["meeting"] ?? "latest")
        return (
          "Draft a short follow-up email for my meeting \"\(meeting.title)\" from "
            + "\(box.friendly(meeting.startedAt)). The full meeting is attached. Thank people briefly, list "
            + "the decisions, then list the action items with their owners. Write it in my voice, in plain "
            + "words, and leave out anything that was not said in the meeting.",
          meeting
        )
      }
    ),
  ]

  static func get(_ box: Toolbox, _ params: JSONObject) async throws -> JSONObject {
    guard let name = params["name"]?.stringValue, let prompt = all.first(where: { $0.name == name }) else {
      throw RPCError.invalidParams("Unknown prompt: \(params["name"]?.stringValue ?? "(no name given)")")
    }
    var arguments: [String: String] = [:]
    for (key, value) in params["arguments"]?.objectValue?.pairs ?? [] {
      guard prompt.arguments.contains(where: { $0.name == key }) else {
        throw RPCError.invalidParams("Invalid params: \"\(key)\" is not an argument of the prompt \(name).")
      }
      guard let text = value.stringValue else {
        throw RPCError.invalidParams("Invalid params: the argument \"\(key)\" must be text.")
      }
      if !text.trimmingCharacters(in: .whitespaces).isEmpty { arguments[key] = text }
    }
    let built: (text: String, attach: Meeting?)
    do {
      built = try await prompt.build(box, arguments)
    } catch let error as AgentError {
      throw RPCError.invalidParams(error.message)
    }
    var messages: [JSONValue] = [["role": "user", "content": ["type": "text", "text": .string(built.text)]]]
    if let meeting = built.attach {
      messages.append([
        "role": "user",
        "content": [
          "type": "resource",
          "resource": [
            "uri": .string(WisperLink.showMeeting(meeting.id).url.absoluteString),
            "mimeType": "text/markdown",
            "text": .string(meeting.markdown(timeZone: box.environment.timeZone)),
          ],
        ],
      ])
    }
    return ["description": .string(prompt.description), "messages": .array(messages)]
  }
}
