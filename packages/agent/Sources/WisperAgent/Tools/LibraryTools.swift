import Foundation
import WisperDomain

// Dictation history, dictionary words, snippets and settings.

extension Catalogue {
  static let dictations: [Tool] = [
    Tool(
      path: ["dictations", "list"],
      title: "List dictations",
      summary: "List recent dictations, or search them.",
      description:
        "Lists what the user has dictated, newest first: the final text, when it was said, the app it "
        + "was typed into, the word count and the length in seconds. With query it returns only "
        + "dictations whose text contains those words. Use it to recall something the user said or wrote "
        + "by voice. Dictations are separate from meetings.",
      params: [
        .text("query", "Only dictations whose text contains this. Case does not matter.", positional: true),
        .number("limit", "The most dictations to return.", in: 1...500, fallback: 20),
        .text("since", "Only dictations made at or after this moment. \(Toolbox.dateHelp)"),
        .text("app", "Only dictations typed into this app, for example Slack."),
      ],
      hints: .reads,
      aliases: [Alias(path: ["dictations", "search"], summary: "The same as \"dictations list <query>\".")],
      example: "wisper dictations search \"flat white\"",
      run: { box, arguments in try await box.listDictations(arguments) }
    )
  ]

  static let dictionary: [Tool] = [
    Tool(
      path: ["dictionary", "list"],
      title: "List dictionary words",
      summary: "List the words Open Wisper has been taught to spell.",
      description:
        "Lists the user's dictionary: names and terms the transcriber should spell the user's way, newest "
        + "first. An entry may also say which misheard form it replaces.",
      hints: .reads,
      example: "wisper dictionary list",
      run: { box, _ in try await box.listWords() }
    ),
    Tool(
      path: ["dictionary", "add"],
      title: "Add a dictionary word",
      summary: "Teach Open Wisper how to spell a name or a term.",
      description:
        "Adds a word or phrase to the user's dictionary so future dictations and meetings spell it that "
        + "way, for example a person's name or a product name. replaces is optional: the wrong form the "
        + "transcriber tends to write, which will then be swapped for the right one. If the word is "
        + "already there it is kept, and its replaces is updated when one is given.",
      params: [
        .text("text", "The correct spelling, for example Kubernetes.", required: true, positional: true),
        .text("replaces", "The misheard form to replace, for example \"cooper netties\"."),
      ],
      hints: .sets,
      example: "wisper dictionary add \"Kubernetes\" --replaces \"cooper netties\"",
      run: { box, arguments in try await box.addWord(arguments) }
    ),
    Tool(
      path: ["dictionary", "remove"],
      title: "Remove a dictionary word",
      summary: "Remove a word from the dictionary.",
      description: "Removes one word from the user's dictionary. Future dictations stop using it.",
      params: [
        .text(
          "word",
          "The word exactly as it is spelled in the dictionary, or its ID (or the first 4 or more characters "
            + "of the ID).",
          required: true,
          positional: true
        )
      ],
      hints: .destroys,
      example: "wisper dictionary remove \"Kubernetes\"",
      run: { box, arguments in try await box.removeWord(arguments) }
    ),
  ]

  static let snippets: [Tool] = [
    Tool(
      path: ["snippets", "list"],
      title: "List snippets",
      summary: "List voice snippets: what the user says and what gets typed.",
      description:
        "Lists the user's snippets, newest first. A snippet is a voice shortcut: when the user says the "
        + "trigger while dictating, the expansion is typed instead.",
      hints: .reads,
      example: "wisper snippets list",
      run: { box, _ in try await box.listSnippets() }
    ),
    Tool(
      path: ["snippets", "add"],
      title: "Add a snippet",
      summary: "Add a voice snippet.",
      description:
        "Adds a voice shortcut: when the user says the trigger while dictating, the expansion is typed "
        + "instead. Good for links, addresses and text the user repeats often. It fails if a snippet with "
        + "the same trigger exists; remove that one first.",
      params: [
        .text(
          "trigger",
          "What the user will say, for example \"my calendar link\".",
          required: true,
          positional: true
        ),
        .text("expansion", "What gets typed, for example a web address.", required: true, positional: true),
      ],
      hints: .adds,
      example: "wisper snippets add \"my calendar link\" \"https://cal.example.com/alex\"",
      run: { box, arguments in try await box.addSnippet(arguments) }
    ),
    Tool(
      path: ["snippets", "remove"],
      title: "Remove a snippet",
      summary: "Remove a voice snippet.",
      description: "Removes one snippet. Saying its trigger no longer types anything special.",
      params: [
        .text(
          "snippet",
          "The snippet's trigger exactly as written, or its ID (or the first 4 or more characters of the ID).",
          required: true,
          positional: true
        )
      ],
      hints: .destroys,
      example: "wisper snippets remove \"my calendar link\"",
      run: { box, arguments in try await box.removeSnippet(arguments) }
    ),
  ]

  static let settings: [Tool] = [
    Tool(
      path: ["settings", "get"],
      title: "Read settings",
      summary: "Show the user's name, language and model choices.",
      description:
        "Returns the harmless parts of the user's Open Wisper settings: their name, the spoken language, "
        + "the transcription and text models, and how meetings and history are handled. It cannot return "
        + "the API key: this tool has no access to it. Settings can only be changed in the app.",
      hints: .reads,
      example: "wisper settings get",
      run: { box, _ in try await box.readSettings() }
    )
  ]
}

extension Toolbox {
  // MARK: Dictations

  fileprivate func listDictations(_ arguments: Arguments) async throws -> ToolOutput {
    let query = arguments.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines)
    var found = try await library.dictations(search: (query?.isEmpty ?? true) ? nil : query, limit: nil)
    if let since = arguments.string("since") {
      let start = try date(from: since, argument: "since")
      found.removeAll { $0.createdAt < start }
    }
    if let app = arguments.string("app") {
      found.removeAll { dictation in !(dictation.appName.map { Toolbox.same($0, app) } ?? false) }
    }
    let shown = Array(found.prefix(arguments.int("limit") ?? 20))
    let entries: [JSONValue] = shown.map { dictation in
      [
        "id": .string(dictation.id.uuidString),
        "created_at": .string(iso(dictation.createdAt)),
        "app": dictation.appName.map(JSONValue.string),
        "mode": dictation.mode == .command ? "command" : nil,
        "text": .string(dictation.text),
        "failure": dictation.failure.map(JSONValue.string),
        "words": .int(dictation.wordCount),
        "seconds": Toolbox.number(dictation.duration),
      ]
    }
    var lines = shown.map { dictation in
      let app = (dictation.appName ?? "-").padding(toLength: 10, withPad: " ", startingAt: 0)
      let text = dictation.failure.map { "(failed: \($0))" } ?? dictation.text
      return "\(friendly(dictation.createdAt))  \(app)  \(text)"
    }
    if shown.isEmpty {
      lines.append("No dictations found.")
    } else if shown.count < found.count {
      lines.append("")
      lines.append("Showing the newest \(shown.count) of \(found.count). Raise --limit to see more.")
    }
    return ToolOutput(
      data: ["total": .int(found.count), "returned": .int(shown.count), "dictations": .array(entries)],
      text: lines.joined(separator: "\n")
    )
  }

  // MARK: Dictionary

  private static func json(_ word: DictionaryWord) -> JSONObject {
    [
      "id": .string(word.id.uuidString),
      "text": .string(word.text),
      "replaces": word.replaces.map(JSONValue.string),
    ]
  }

  private static func line(for word: DictionaryWord) -> String {
    "\(short(word.id))  \(word.text)" + (word.replaces.map { "  (replaces \"\($0)\")" } ?? "")
  }

  /// Picks one entry by its exact name or by its ID (or the start of it).
  private static func pick<Item>(
    _ reference: String,
    from items: [Item],
    kind: String,
    name: (Item) -> String,
    id: (Item) -> UUID
  ) throws -> Item {
    let wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    let named = items.filter { same(name($0), wanted) }
    let found = named.isEmpty ? (matching(wanted, in: items, id: id) ?? []) : named
    switch found.count {
    case 1: return found[0]
    case 0: throw AgentError.failed("There is no \(kind) \"\(reference)\". List them to see what is there.")
    default: throw AgentError.failed("More than one \(kind) matches \"\(reference)\". Use its ID instead.")
    }
  }

  fileprivate func listWords() async throws -> ToolOutput {
    let words = try await library.words()
    return ToolOutput(
      data: ["total": .int(words.count), "words": .array(words.map { .object(Toolbox.json($0)) })],
      text: words.isEmpty
        ? "The dictionary is empty." : words.map(Toolbox.line(for:)).joined(separator: "\n")
    )
  }

  fileprivate func addWord(_ arguments: Arguments) async throws -> ToolOutput {
    let text = arguments.text("text").trimmingCharacters(in: .whitespacesAndNewlines)
    let replaces = arguments.string("replaces")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let existing = try await library.words().first { Toolbox.same($0.text, text) }
    var word = existing ?? DictionaryWord(text: text, createdAt: now)
    if let replaces, !replaces.isEmpty { word.replaces = replaces }
    if existing == nil || existing != word { try await library.save(word) }
    var data = Toolbox.json(word)
    data["added"] = .bool(existing == nil)
    let verb = existing == nil ? "Added" : (existing == word ? "Already there" : "Updated")
    return ToolOutput(data: data, text: "\(verb):\n  " + Toolbox.line(for: word))
  }

  fileprivate func removeWord(_ arguments: Arguments) async throws -> ToolOutput {
    let word = try Toolbox.pick(
      arguments.text("word"),
      from: try await library.words(),
      kind: "dictionary word",
      name: \.text,
      id: \.id
    )
    try await library.deleteWord(word.id)
    var data = Toolbox.json(word)
    data["removed"] = true
    return ToolOutput(data: data, text: "Removed \"\(word.text)\" from the dictionary.")
  }

  // MARK: Snippets

  private static func json(_ snippet: Snippet) -> JSONObject {
    [
      "id": .string(snippet.id.uuidString),
      "trigger": .string(snippet.trigger),
      "expansion": .string(snippet.expansion),
    ]
  }

  private static func line(for snippet: Snippet) -> String {
    "\(short(snippet.id))  \"\(snippet.trigger)\"  ->  \(clipped(snippet.expansion, to: 70))"
  }

  fileprivate func listSnippets() async throws -> ToolOutput {
    let snippets = try await library.snippets()
    return ToolOutput(
      data: ["total": .int(snippets.count), "snippets": .array(snippets.map { .object(Toolbox.json($0)) })],
      text: snippets.isEmpty
        ? "There are no snippets." : snippets.map(Toolbox.line(for:)).joined(separator: "\n")
    )
  }

  fileprivate func addSnippet(_ arguments: Arguments) async throws -> ToolOutput {
    let trigger = arguments.text("trigger").trimmingCharacters(in: .whitespacesAndNewlines)
    if let existing = try await library.snippets().first(where: { Toolbox.same($0.trigger, trigger) }) {
      throw AgentError.failed(
        "There is already a snippet for \"\(existing.trigger)\" (\(existing.id.uuidString)). "
          + "Remove it first, or use another trigger."
      )
    }
    let snippet = Snippet(trigger: trigger, expansion: arguments.text("expansion"), createdAt: now)
    try await library.save(snippet)
    return ToolOutput(data: Toolbox.json(snippet), text: "Added:\n  " + Toolbox.line(for: snippet))
  }

  fileprivate func removeSnippet(_ arguments: Arguments) async throws -> ToolOutput {
    let snippet = try Toolbox.pick(
      arguments.text("snippet"),
      from: try await library.snippets(),
      kind: "snippet",
      name: \.trigger,
      id: \.id
    )
    try await library.deleteSnippet(snippet.id)
    var data = Toolbox.json(snippet)
    data["removed"] = true
    return ToolOutput(data: data, text: "Removed the snippet \"\(snippet.trigger)\".")
  }

  // MARK: Settings

  /// The parts of the settings that are safe to show. The API key is not in
  /// `Settings` at all, and the server address is left out because an address
  /// can carry a password.
  fileprivate func readSettings() async throws -> ToolOutput {
    let settings = try await library.settings()
    let language =
      settings.language.map { code in
        SpokenLanguage.all.first { $0.code == code }.map { "\($0.name) (\(code))" } ?? code
      } ?? "detected automatically"
    let server = settings.apiBaseURL == nil ? "OpenAI" : "a custom server"
    let data: JSONObject = [
      "user_name": .string(settings.userName),
      "language": settings.language.map(JSONValue.string) ?? "auto",
      "transcription_model": .string(settings.transcriptionModel),
      "text_model": .string(settings.textModel),
      "server": .string(settings.apiBaseURL == nil ? "openai" : "custom"),
      "smart_formatting": .bool(settings.smartFormatting),
      "history_retention": .string(settings.historyRetention.rawValue),
      "meetings": [
        "capture_system_audio": .bool(settings.meetings.captureSystemAudio),
        "auto_summarize": .bool(settings.meetings.autoSummarize),
        "keep_audio": .bool(settings.meetings.keepAudio),
      ],
      "api_key": "not available to this tool",
    ]
    let rows: [(String, String)] = [
      ("Name", settings.userName.isEmpty ? "(not set)" : settings.userName),
      ("Language", language),
      ("Transcription model", settings.transcriptionModel),
      ("Text model", settings.textModel),
      ("Server", server),
      ("Smart formatting", settings.smartFormatting ? "on" : "off"),
      ("Keep history", settings.historyRetention.label),
      ("Meeting notes", settings.meetings.autoSummarize ? "written automatically" : "off"),
      ("Record computer sound", settings.meetings.captureSystemAudio ? "on" : "off"),
      ("API key", "kept in the Keychain. This tool cannot read it."),
    ]
    let lines = rows.map { ($0.0 + ":").padding(toLength: 24, withPad: " ", startingAt: 0) + $0.1 }
    return ToolOutput(data: data, text: lines.joined(separator: "\n"))
  }
}
