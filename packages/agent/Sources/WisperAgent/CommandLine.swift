import Foundation
import WisperDomain

/// The shell front end: turns `wisper meetings list --limit 5` into a call on
/// the catalogue and prints the result.
struct CommandLineFrontEnd {
  let source: LazyLibrary
  let environment: WisperAgent.Environment
  let io: WisperAgent.IO

  static let success: Int32 = 0
  static let failed: Int32 = 1
  static let usage: Int32 = 2

  /// A catalogue tool reached by one of its command-line spellings.
  struct Command {
    var tool: Tool
    var path: [String]
    var summary: String
    var preset: JSONObject

    var hidden: Set<String> { Set(preset.keys) }
  }

  static let commands: [Command] = Catalogue.tools.flatMap { tool in
    [Command(tool: tool, path: tool.path, summary: tool.summary, preset: [:])]
      + tool.aliases.map { Command(tool: tool, path: $0.path, summary: $0.summary, preset: $0.preset) }
  }

  /// Commands that are not catalogue tools.
  static let extras: [(name: String, summary: String)] = [
    ("mcp", "Serve every tool to an AI agent over the Model Context Protocol (stdio)."),
    ("mcp-config", "Print the settings to paste into an MCP client."),
    ("tools", "List every tool, as text, as JSON (--json) or as Markdown (--markdown)."),
    ("doctor", "Check the data folder, the counts and whether the app is running."),
  ]

  private var box: Toolbox { Toolbox(library: source.library, environment: environment) }

  func run(_ arguments: [String]) async -> Int32 {
    var words = arguments
    // Flags that mean the same everywhere. Everything after a bare "--" is left alone.
    func take(_ flags: String...) -> Bool {
      var found = false
      let end = words.firstIndex(of: "--") ?? words.endIndex
      for index in words[..<end].indices.reversed() where flags.contains(words[index]) {
        words.remove(at: index)
        found = true
      }
      return found
    }
    let json = take("--json")
    var wantsHelp = take("--help", "-h")
    if take("--version", "-v") || words == ["version"] {
      io.output("wisper \(WisperAgent.version)")
      return Self.success
    }
    if words.first == "help" {
      wantsHelp = true
      words.removeFirst()
    }
    guard let first = words.first else {
      io.output(Help.overview(environment))
      return Self.success
    }

    if Self.extras.contains(where: { $0.name == first }) {
      if wantsHelp {
        io.output(Help.extra(first, environment))
        return Self.success
      }
      let rest = Array(words.dropFirst())
      switch first {
      case "mcp":
        guard rest.isEmpty else {
          return wrong("\"wisper mcp\" takes no arguments.", hint: "wisper mcp --help")
        }
        await MCPServer(source: source, environment: environment, io: io).serve(io.input)
        return Self.success
      case "mcp-config":
        guard rest.isEmpty else {
          return wrong("\"wisper mcp-config\" takes no arguments.", hint: "wisper mcp-config --help")
        }
        io.output(Help.clientConfig(environment).serialized(pretty: true))
        return Self.success
      case "tools":
        return tools(rest, json: json)
      default:
        guard rest.isEmpty else {
          return wrong("\"wisper doctor\" takes no arguments.", hint: "wisper doctor --help")
        }
        return await doctor(json: json)
      }
    }

    let inGroup = Self.commands.filter { $0.path[0] == first }
    guard !inGroup.isEmpty else {
      let known = Catalogue.groups.map(\.key) + Self.extras.map(\.name)
      return wrong(
        "There is no command \"\(Limits.echo(first))\"." + Self.suggestion(for: first, among: known),
        hint: "wisper --help"
      )
    }
    guard words.count > 1 else {
      io.output(Help.group(first))
      return Self.success
    }
    guard let command = inGroup.first(where: { $0.path[1] == words[1] }) else {
      return wrong(
        "There is no command \"\(first) \(Limits.echo(words[1]))\"."
          + Self.suggestion(for: words[1], among: inGroup.map { $0.path[1] }),
        hint: "wisper \(first) --help"
      )
    }
    if wantsHelp {
      io.output(Help.command(command))
      return Self.success
    }

    let usageLine = command.tool.usage(path: command.path, hiding: command.hidden)
    let hint = "wisper \(command.path.joined(separator: " ")) --help"
    do {
      let raw = try Self.parse(Array(words.dropFirst(2)), for: command)
      let output = try await command.tool.call(raw, in: box)
      // Titles, notes and transcripts are printed as they are stored, except for control
      // characters: text from a meeting must not be able to send commands to the terminal.
      // JSON output needs no such care, because JSON writes those characters as escapes.
      io.output(
        json ? JSONValue.object(output.data).serialized(pretty: true) : Toolbox.printable(output.text)
      )
      return Self.success
    } catch let error as AgentError {
      switch error.kind {
      case .usage:
        return wrong(error.message, usage: usageLine, hint: hint)
      case .failed:
        io.error("wisper: \(Toolbox.printable(error.message))")
        return Self.failed
      }
    } catch {
      io.error("wisper: \(Toolbox.printable(error.localizedDescription))")
      return Self.failed
    }
  }

  private func wrong(_ message: String, usage: String? = nil, hint: String) -> Int32 {
    io.error("wisper: \(Toolbox.printable(message))")
    if let usage { io.error("Usage: \(usage)") }
    io.error("Run \"\(hint)\" to see how it works.")
    return Self.usage
  }

  /// The known word closest to a mistyped one, as a sentence to add to an error.
  static func suggestion(for word: String, among known: [String]) -> String {
    func distance(_ a: String, _ b: String) -> Int {
      let a = Array(a), b = Array(b)
      var row = Array(0...b.count)
      for i in a.indices {
        var previous = row[0]
        row[0] = i + 1
        for j in b.indices {
          let current = row[j + 1]
          row[j + 1] = min(previous + (a[i] == b[j] ? 0 : 1), row[j] + 1, current + 1)
          previous = current
        }
      }
      return row[b.count]
    }
    // A word far longer than any command is not a slip of the finger.
    guard !Limits.isLonger(word, than: 40) else { return "" }
    let lowered = word.lowercased()
    let close = known.map { ($0, distance(lowered, $0)) }.filter { $0.1 <= max(2, lowered.count / 3) }
    guard let best = close.min(by: { $0.1 < $1.1 }) else { return "" }
    return " Did you mean \"\(best.0)\"?"
  }

  /// Turns the words after the command into raw tool arguments.
  ///
  /// `--name value`, `--name=value`, `--flag`, `--no-flag`; a choice can be
  /// given by its value alone (`--open` for `--status open`); values without
  /// a flag fill the positional params in order; `--` ends the flags.
  static func parse(_ words: [String], for command: Command) throws -> JSONObject {
    let tool = command.tool
    var raw = command.preset
    var loose: [String] = []
    var index = 0
    var flagsEnded = false
    while index < words.count {
      let word = words[index]
      index += 1
      if flagsEnded || !word.hasPrefix("--") {
        loose.append(word)
        continue
      }
      if word == "--" {
        flagsEnded = true
        continue
      }
      let body = word.dropFirst(2)
      let split = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let name = split[0].replacingOccurrences(of: "-", with: "_")
      var inline = split.count > 1 ? String(split[1]) : nil

      let open = tool.params.filter { !command.hidden.contains($0.name) }
      var param = open.first { $0.name == name }
      if param == nil, name.hasPrefix("no_"), inline == nil,
        let negated = open.first(where: { $0.name == name.dropFirst(3) && $0.kind == .boolean })
      {
        param = negated
        inline = "false"
      }
      if param == nil, inline == nil {
        let choices = open.filter { param in
          if case .choice(let values) = param.kind { return values.contains(name) }
          return false
        }
        if choices.count == 1 {
          param = choices[0]
          inline = name
        }
      }
      guard let param else {
        let flags = open.filter { !$0.positional }.map(\.flag)
        throw AgentError.usage(
          "\"\(Limits.echo(String(split[0]).isEmpty ? word : "--" + split[0]))\" is not an option of this command."
            + (flags.isEmpty ? "" : " Options: \(flags.joined(separator: ", ")).")
        )
      }
      let value: String
      if let inline {
        value = inline
      } else if param.kind == .boolean {
        value = "true"
      } else if index < words.count {
        value = words[index]
        index += 1
      } else {
        throw AgentError.usage("\"\(param.flag)\" needs a value.")
      }
      if param.kind == .strings {
        let more = try param.checked(.string(value)).arrayValue ?? []
        raw[param.name] = .array((raw[param.name]?.arrayValue ?? []) + more)
      } else {
        raw[param.name] = .string(value)
      }
    }

    let places = tool.params.filter {
      $0.positional && !command.hidden.contains($0.name) && raw[$0.name] == nil
    }
    for (place, value) in zip(places, loose) { raw[place.name] = .string(value) }
    if loose.count > places.count {
      // Unquoted text: `wisper actions add latest Send the deck` means one text of three words.
      guard let last = places.last, last.kind == .string else {
        throw AgentError.usage(
          "Too many arguments: \"\(Limits.echo(loose[places.count]))\" was not expected."
        )
      }
      raw[last.name] = .string(loose[(places.count - 1)...].joined(separator: " "))
    }
    return raw
  }

  // MARK: Commands outside the catalogue

  private func tools(_ rest: [String], json: Bool) -> Int32 {
    if rest == ["--markdown"] {
      io.output(Help.reference())
      return Self.success
    }
    guard rest.isEmpty else {
      return wrong("\"wisper tools\" takes only --json or --markdown.", hint: "wisper tools --help")
    }
    if json {
      io.output(JSONValue.array(Catalogue.tools.map(\.definition)).serialized(pretty: true))
    } else {
      io.output(Help.toolList())
    }
    return Self.success
  }

  private func doctor(json: Bool) async -> Int32 {
    let folder = environment.dataFolder
    let folderExists = FileManager.default.fileExists(atPath: folder.path)
    let running = await Live.appIsRunning()
    var data: JSONObject = [
      "version": .string(WisperAgent.version),
      "tool": .string(environment.executablePath),
      "data_folder": .string(folder.path),
      "data_folder_exists": .bool(folderExists),
      "app_running": running.map(JSONValue.bool),
      "mcp_protocol_versions": .strings(MCPServer.modernVersions + MCPServer.handshakeVersions),
    ]
    var lines = [
      "wisper \(WisperAgent.version)",
      "Tool:         \(environment.executablePath)",
      "Data folder:  \(folder.path)"
        + (folderExists ? "" : "  (not there yet: open the app once to create it)"),
    ]
    var code = Self.success
    do {
      let library = source.library
      let meetings = try await library.meetings()
      let dictations = try await library.dictations()
      let words = try await library.words()
      let snippets = try await library.snippets()
      let recording = meetings.first { $0.status == .recording }
      let open = meetings.reduce(0) { $0 + ($1.notes?.actionItems.filter { !$0.done }.count ?? 0) }
      data["meetings"] = .int(meetings.count)
      data["open_action_items"] = .int(open)
      data["dictations"] = .int(dictations.count)
      data["dictionary_words"] = .int(words.count)
      data["snippets"] = .int(snippets.count)
      data["recording"] = .bool(recording != nil)
      lines += [
        "Meetings:     \(meetings.count)" + (recording.map { "  (recording \"\($0.name)\" now)" } ?? ""),
        "Action items: \(open) open",
        "Dictations:   \(dictations.count)",
        "Dictionary:   \(Toolbox.count(words.count, "word"))",
        "Snippets:     \(snippets.count)",
      ]
    } catch {
      data["problem"] = .string(error.localizedDescription)
      lines.append("Problem:      \(error.localizedDescription)")
      code = Self.failed
    }
    let app =
      switch running {
      case true?: "running"
      case false?: "not running (recording start and stop need it)"
      case nil: "cannot tell"
      }
    lines.append("App:          \(app)")
    lines.append(
      "MCP:          speaks \((MCPServer.modernVersions + MCPServer.handshakeVersions).joined(separator: ", "))"
    )
    lines.append("API key:      kept in the Keychain. This tool cannot read it.")
    io.output(
      json
        ? JSONValue.object(data).serialized(pretty: true) : Toolbox.printable(lines.joined(separator: "\n"))
    )
    return code
  }
}
