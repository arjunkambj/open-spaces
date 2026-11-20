import Foundation
import SpacesDomain

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
      example: "spaces dictations search \"flat white\"",
      run: { box, arguments in try await box.listDictations(arguments) }
    )
  ]

  static let dictionary: [Tool] = [
    Tool(
      path: ["dictionary", "list"],
      title: "List dictionary words",
      summary: "List the words Spaces has been taught to spell.",
      description:
        "Lists the user's dictionary: names and terms the transcriber should spell the user's way, newest "
        + "first. An entry may also say which misheard form it replaces.",
      hints: .reads,
      example: "spaces dictionary list",
      run: { box, _ in try await box.listWords() }
    ),
    Tool(
      path: ["dictionary", "add"],
      title: "Add a dictionary word",
      summary: "Teach Spaces how to spell a name or a term.",
      description:
        "Adds a word or phrase to the user's dictionary so future dictations and meetings spell it that "
        + "way, for example a person's name or a product name. replaces is optional: the wrong form the "
        + "transcriber tends to write. From then on the app swaps that form for the right one in "
        + "everything the user dictates, and types the result into whatever app they are using, so "
        + "only add what the user asked for. If the word is already there it is kept, and its replaces "
        + "is updated when one is given. Both are one line of at most \(Limits.word) characters.",
      params: [
        .text(
          "text",
          "The correct spelling, for example Kubernetes.",
          required: true,
          positional: true,
          limit: Limits.word
        ),
        .text(
          "replaces",
          "The misheard form to replace, for example \"cooper netties\".",
          limit: Limits.word
        ),
      ],
      hints: .sets,
      example: "spaces dictionary add \"Kubernetes\" --replaces \"cooper netties\"",
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
      example: "spaces dictionary remove \"Kubernetes\"",
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
      example: "spaces snippets list",
      run: { box, _ in try await box.listSnippets() }
    ),
    Tool(
      path: ["snippets", "add"],
      title: "Add a snippet",
      summary: "Add a voice snippet.",
      description:
        "Adds a voice shortcut: from then on, whenever the user says the trigger while dictating, the app "
        + "types the expansion instead, into whatever app they are using at that moment (a chat, an "
        + "email, a terminal). So only add a snippet the user asked for, with exactly the text they "
        + "asked for. Good for links, addresses and text the user repeats often. In command mode, saying "
        + "the trigger on its own sends the expansion as the instruction, so a snippet can also hold a "
        + "command the user gives often. The trigger is one line of two or more words, or one word "
        + "of at least \(Toolbox.shortestTrigger) letters. It "
        + "fails if a snippet with the same trigger exists; remove that one first.",
      params: [
        .text(
          "trigger",
          "What the user will say, for example \"my calendar link\". At most \(Limits.trigger) characters.",
          required: true,
          positional: true,
          limit: Limits.trigger
        ),
        .text(
          "expansion",
          "What gets typed, for example a web address. At most \(Limits.plain(Limits.expansion)) "
            + "characters.",
          required: true,
          positional: true,
          limit: Limits.expansion
        ),
      ],
      hints: .adds,
      example: "spaces snippets add \"my calendar link\" \"https://cal.example.com/alex\"",
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
      example: "spaces snippets remove \"my calendar link\"",
      run: { box, arguments in try await box.removeSnippet(arguments) }
    ),
  ]

  static let settings: [Tool] = [
    Tool(
      path: ["settings", "get"],
      title: "Read settings",
      summary: "Show the user's name, language and model choices.",
      description:
        "Returns the harmless parts of the user's Spaces settings: their name, the spoken language, "
        + "the transcription and text models, and how meetings and history are handled. It cannot return "
        + "the API key: this tool has no access to it. Settings can only be changed in the app.",
      hints: .reads,
      returnsContent: false,
      example: "spaces settings get",
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
    "\(short(word.id))  \(oneLine(word.text))"
      + (word.replaces.map { "  (replaces \"\(oneLine($0))\")" } ?? "")
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
    case 0:
      throw AgentError.failed(
        "There is no \(kind) \"\(Limits.echo(reference))\". List them to see what is there."
      )
    default:
      throw AgentError.failed(
        "More than one \(kind) matches \"\(Limits.echo(reference))\". Use its ID instead."
      )
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

  // What an agent saves here, the app later types for the user. So a word and the form it
  // replaces are one short line each, checked before anything is stored.
  fileprivate func addWord(_ arguments: Arguments) async throws -> ToolOutput {
    let text = try Toolbox.phrase(arguments.text("text"), argument: "text", limit: Limits.word)
    var replaces: String?
    if let given = arguments.string("replaces"), !given.trimmingCharacters(in: .whitespaces).isEmpty {
      replaces = try Toolbox.phrase(given, argument: "replaces", limit: Limits.word)
    }
    let words = try await library.words()
    let existing = words.first { Toolbox.same($0.text, text) }
    guard existing != nil || words.count < Limits.words else {
      throw AgentError.failed(
        "The dictionary already holds \(Limits.plain(Limits.words)) words, the most it can. Remove some "
          + "first."
      )
    }
    var word = existing ?? DictionaryWord(text: text, createdAt: now)
    if let replaces { word.replaces = replaces }
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
    "\(short(snippet.id))  \"\(oneLine(snippet.trigger))\"  ->  \(clipped(snippet.expansion, to: 70))"
  }

  fileprivate func listSnippets() async throws -> ToolOutput {
    let snippets = try await library.snippets()
    return ToolOutput(
      data: ["total": .int(snippets.count), "snippets": .array(snippets.map { .object(Toolbox.json($0)) })],
      text: snippets.isEmpty
        ? "There are no snippets." : snippets.map(Toolbox.line(for:)).joined(separator: "\n")
    )
  }

  /// A one-word trigger needs at least this many letters. The app's own screen has the same rule.
  static let shortestTrigger = 4

  // A snippet is text the app will type for the user later, into whatever app they are in.
  // An agent that was tricked must not be able to plant one that goes off by accident (a
  // trigger as common as "okay") or one that hides something (control characters).
  fileprivate func addSnippet(_ arguments: Arguments) async throws -> ToolOutput {
    let trigger = try Toolbox.phrase(arguments.text("trigger"), argument: "trigger", limit: Limits.trigger)
    let spoken = Toolbox.spokenWords(trigger)
    let letters = spoken.joined().filter { $0.isLetter || $0.isNumber }.count
    guard letters > 0, spoken.count >= 2 || letters >= Toolbox.shortestTrigger else {
      throw AgentError.usage(
        "\"trigger\" is too short. Use two or more words, or one word of at least "
          + "\(Toolbox.shortestTrigger) letters: a very short phrase would go off by accident."
      )
    }
    // Line endings from other systems are plain line breaks. The ends are trimmed, as in the app.
    let expansion = arguments.text("expansion").replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !expansion.isEmpty else { throw AgentError.usage("\"expansion\" must not be empty.") }
    let unwanted = expansion.unicodeScalars.contains {
      ($0.isControl && $0 != "\n" && $0 != "\t") || $0.reordersText
    }
    guard !unwanted else {
      throw AgentError.usage(
        "\"expansion\" must be plain text. Line breaks and tabs are fine; other control characters are not."
      )
    }
    let snippets = try await library.snippets()
    let key = spoken.joined(separator: " ")
    let twin = snippets.first {
      Toolbox.same($0.trigger, trigger) || Toolbox.spokenWords($0.trigger).joined(separator: " ") == key
    }
    if let existing = twin {
      throw AgentError.failed(
        "There is already a snippet for \"\(existing.trigger)\" (\(existing.id.uuidString)). "
          + "Remove it first, or use another trigger."
      )
    }
    guard snippets.count < Limits.snippets else {
      throw AgentError.failed(
        "There are already \(Limits.snippets) snippets, the most there can be. Remove some first."
      )
    }
    let snippet = Snippet(trigger: trigger, expansion: expansion, createdAt: now)
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
      ("API key", "kept in its own file. This tool never reads it."),
    ]
    let lines = rows.map { ($0.0 + ":").padding(toLength: 24, withPad: " ", startingAt: 0) + $0.1 }
    return ToolOutput(data: data, text: lines.joined(separator: "\n"))
  }
}
