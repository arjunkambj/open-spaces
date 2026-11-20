import Foundation
import SpacesDomain

/// Everything `spaces` prints to explain itself. All of it is generated from
/// the catalogue, so help can never describe a command that is not there.
enum Help {
  private static let width = 100

  /// Breaks text into lines no longer than `width`, each starting with `indent`.
  static func wrap(_ text: String, indent: String = "", width: Int = width) -> String {
    var lines: [String] = []
    var line = ""
    for word in text.split(separator: " ") {
      if !line.isEmpty && indent.count + line.count + 1 + word.count > width {
        lines.append(indent + line)
        line = ""
      }
      line += (line.isEmpty ? "" : " ") + word
    }
    if !line.isEmpty { lines.append(indent + line) }
    return lines.joined(separator: "\n")
  }

  /// Rows of a name and what it means, with the meanings lined up and wrapped.
  private static func table(_ rows: [(String, String)], indent: String = "  ") -> String {
    let column = min(26, (rows.map(\.0.count).max() ?? 0) + 2)
    return rows.map { name, meaning in
      let lead = indent + name.padding(toLength: max(column, name.count + 2), withPad: " ", startingAt: 0)
      let pad = String(repeating: " ", count: lead.count)
      let wrapped = wrap(meaning, width: width - lead.count).split(separator: "\n")
      return lead + wrapped.joined(separator: "\n" + pad)
    }.joined(separator: "\n")
  }

  private static func rows(inGroup group: String) -> [(String, String)] {
    CommandLineFrontEnd.commands.filter { $0.path[0] == group }
      .map { ($0.path.joined(separator: " "), $0.summary) }
  }

  // MARK: Screens

  static func overview(_ environment: SpacesAgent.Environment) -> String {
    var parts = [
      "spaces \(SpacesAgent.version): your Spaces meetings, notes and dictations, for the terminal and for AI agents.",
      """
      Usage
        spaces <command> [arguments] [--json]
        spaces <command> --help
      """,
    ]
    for group in Catalogue.groups {
      parts.append(group.title + "\n" + table(rows(inGroup: group.key)))
    }
    parts.append("For agents\n" + table(CommandLineFrontEnd.extras.map { ($0.name, $0.summary) }))
    parts.append(
      "Options\n"
        + table([
          ("--json", "Print the result as JSON instead of text. Works with every command."),
          ("--help, -h", "Explain a command and list its arguments."),
          ("--version", "Print the version."),
        ])
    )
    parts.append(
      "Meetings, action items and dates\n"
        + table([
          ("<meeting>", "A full ID, the first 4 or more characters of one, or \"latest\"."),
          ("<action>", "A full action item ID, or the first 4 or more characters of one."),
          ("dates", "2026-11-18, 2026-11-18T09:30:00+05:30, today, yesterday, or an age: 36h, 7d, 2w."),
          ("times", "A place in a recording: seconds (90) or mm:ss (1:30)."),
        ])
    )
    parts.append(
      "Exit codes\n"
        + table([
          ("0", "Done."),
          (
            "1",
            "It could not be done: not found, or the app did not answer. The reason is on standard error."
          ),
          ("2", "The command was written wrong."),
        ])
    )
    parts.append(
      """
      Examples
        spaces meetings list --since 7d
        spaces meetings get latest
        spaces meetings search "pricing"
        spaces meetings transcript latest --from 10:00 --to 15:00
        spaces actions list --open --owner Alex
        spaces actions done 7B1D4F02
        spaces dictionary add "Kubernetes" --replaces "cooper netties"
        spaces recording start --title "Design review"
        spaces mcp-config
      """
    )
    parts.append(
      "Data\n"
        + wrap(
          "Everything is read from and saved to \(environment.dataFolder.path) on this computer. Nothing is "
            + "sent anywhere. Set \(SpacesPaths.homeVariable) to use another folder. The API key is kept in "
            + "its own file and this tool never reads it.",
          indent: "  "
        )
    )
    return parts.joined(separator: "\n\n")
  }

  static func group(_ key: String) -> String {
    let title = Catalogue.groups.first { $0.key == key }?.title ?? key
    return [
      "\(title)\n" + table(rows(inGroup: key)),
      "Run \"spaces \(key) <command> --help\" to see a command's arguments.",
    ].joined(separator: "\n\n")
  }

  private static func note(for param: Param) -> String {
    var note = param.help
    if case .integer(let range) = param.kind, range.upperBound < 1_000_000 {
      note += " From \(range.lowerBound) to \(range.upperBound)."
    }
    if case .strings = param.kind { note += " Separate several with commas, or repeat the option." }
    if param.kind == .string, param.limit > Limits.path {
      note += " At most \(Limits.plain(param.limit)) characters."
    }
    switch param.fallback {
    case .string(let value)?: note += " Default: \(value)."
    case .int(let value)?: note += " Default: \(value)."
    case .bool(true)?: note += " It is on unless you turn it off with this."
    default: break
    }
    return note
  }

  static func command(_ command: CommandLineFrontEnd.Command) -> String {
    let tool = command.tool
    let shown = tool.params.filter { !command.hidden.contains($0.name) }
    var parts = [tool.usage(path: command.path, hiding: command.hidden), wrap(tool.guidance)]
    var rows: [(String, String)] = shown.map { param in
      param.positional ? ("<\(param.name)>", note(for: param)) : (param.usage, note(for: param))
    }
    rows.append(("--json", "Print the result as JSON instead of text."))
    parts.append("Arguments\n" + table(rows))
    let others = CommandLineFrontEnd.commands.filter { $0.tool.name == tool.name && $0.path != command.path }
    if !others.isEmpty {
      parts.append(
        "Also written as\n"
          + others.map { "  " + tool.usage(path: $0.path, hiding: $0.hidden) }.joined(separator: "\n")
      )
    }
    parts.append("Example\n  \(tool.example)")
    parts.append("As an MCP tool this is \"\(tool.name)\".")
    return parts.joined(separator: "\n\n")
  }

  static func extra(_ name: String, _ environment: SpacesAgent.Environment) -> String {
    let path = environment.executablePath
    switch name {
    case "mcp":
      return [
        "spaces mcp",
        wrap(
          "Serves every spaces tool to an AI agent over the Model Context Protocol. It reads one JSON "
            + "message per line from standard input and writes one per line to standard output, until the "
            + "input ends. Logs go to standard error. You do not run this yourself: an MCP client such as "
            + "Claude Code, Claude Desktop or Cursor starts it. Run \"spaces mcp-config\" for the settings "
            + "to give that client."
        ),
        "It offers\n"
          + table([
            ("tools", "The \(Catalogue.tools.count) tools listed by \"spaces tools\"."),
            ("resources", "Each meeting as a Markdown document at \(SpacesLink.scheme)://meetings/<id>."),
            ("prompts", Prompts.all.map(\.title).joined(separator: "; ") + "."),
          ]),
        "Protocol versions: \((MCPServer.modernVersions + MCPServer.handshakeVersions).joined(separator: ", ")).",
        "Claude Code\n  claude mcp add open-spaces -- \"\(path)\" mcp",
      ].joined(separator: "\n\n")
    case "mcp-config":
      return [
        "spaces mcp-config",
        wrap(
          "Prints the JSON to paste into an MCP client's settings file so the client can start this tool. "
            + "It uses the full path of this copy of spaces. Claude Desktop, Cursor and most other clients "
            + "read this shape."
        ),
        "Where it goes\n"
          + table([
            ("Claude Code", "Skip the file and run: claude mcp add open-spaces -- \"\(path)\" mcp"),
            ("Claude Desktop", "~/Library/Application Support/Claude/claude_desktop_config.json"),
            ("Cursor", "~/.cursor/mcp.json, or .cursor/mcp.json inside one project"),
          ]),
      ].joined(separator: "\n\n")
    case "tools":
      return [
        "spaces tools [--json | --markdown]",
        wrap(
          "Lists every tool: its command, its MCP name and what it does. With --json it prints the exact "
            + "tool definitions an MCP client receives, including each tool's argument schema. With "
            + "--markdown it prints the tool tables used in the documentation."
        ),
      ].joined(separator: "\n\n")
    default:
      return [
        "spaces doctor [--json]",
        wrap(
          "Checks that the tool can work: where the data folder is and whether it exists, how many "
            + "meetings, dictations, dictionary words and snippets it holds, whether a meeting is being "
            + "recorded, and whether the Spaces app seems to be running."
        ),
      ].joined(separator: "\n\n")
    }
  }

  /// The settings an MCP client needs to start this tool.
  static func clientConfig(_ environment: SpacesAgent.Environment) -> JSONValue {
    var server: JSONObject = ["command": .string(environment.executablePath), "args": ["mcp"]]
    if let home = environment.homeOverride {
      server["env"] = [SpacesPaths.homeVariable: .string(home)]
    }
    return ["mcpServers": ["open-spaces": .object(server)]]
  }

  // MARK: Tool lists

  private static func effect(_ hints: Hints) -> String {
    if hints.readOnly { return "Reads" }
    if hints.openWorld { return "Reads, or saves a new file" }
    if hints.destructive { return "Overwrites or deletes" }
    return hints.idempotent ? "Adds or changes" : "Adds"
  }

  static func toolList() -> String {
    Catalogue.groups.map { group in
      let tools = Catalogue.tools.filter { $0.group == group.key }
      return group.title + "\n"
        + tools.map { tool in
          "  " + tool.usage() + "\n"
            + wrap("\(tool.summary) (\(effect(tool.hints)). MCP tool: \(tool.name))", indent: "      ")
        }.joined(separator: "\n")
    }.joined(separator: "\n\n")
  }

  /// The tool tables in `docs/agents.md`.
  static func reference() -> String {
    Catalogue.groups.map { group in
      var lines = [
        "### \(group.title)", "", "| MCP tool | Command | What it does | Effect |",
        "| --- | --- | --- | --- |",
      ]
      for tool in Catalogue.tools where tool.group == group.key {
        let usage = tool.usage().replacingOccurrences(of: "|", with: "\\|")
        lines.append("| `\(tool.name)` | `\(usage)` | \(tool.summary) | \(effect(tool.hints)) |")
      }
      return lines.joined(separator: "\n")
    }.joined(separator: "\n\n")
  }
}
