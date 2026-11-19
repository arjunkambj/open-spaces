import Foundation
import Testing
import WisperAgent
import WisperDomain

@Suite("Command line")
struct CommandLineTests {
  let harness = Harness()

  /// The command-line words for an MCP tool name: `meetings_add_note` is `meetings add-note`.
  private func words(for tool: String) -> [String] {
    let parts = tool.split(separator: "_", maxSplits: 1).map(String.init)
    return [parts[0], parts[1].replacingOccurrences(of: "_", with: "-")]
  }

  private func toolNames() async -> [String] {
    await harness.cli("tools", "--json").json.array.compactMap { $0["name"].string }
  }

  // MARK: Help

  @Test func helpListsEverything() async throws {
    let help = await harness.cli("--help")
    #expect(help.code == 0 && help.err.isEmpty)
    for tool in await toolNames() {
      #expect(help.out.contains(words(for: tool).joined(separator: " ")), "\(tool) is missing from --help")
    }
    for word in [
      "mcp", "mcp-config", "doctor", "tools", "--json", "Exit codes", "latest", "OPEN_WISPER_HOME",
    ] {
      #expect(help.out.contains(word))
    }
    #expect(await harness.cli().out == help.out)
    #expect(await harness.cli("help").out == help.out)
    #expect(await harness.cli("-h").out == help.out)
  }

  @Test func everyCommandExplainsItself() async throws {
    let names = await toolNames()
    #expect(names.count == 24)
    for tool in names {
      let path = words(for: tool)
      let help = await harness.cli(path + ["--help"])
      #expect(help.code == 0, "\(tool)")
      #expect(help.out.hasPrefix("wisper \(path.joined(separator: " "))"))
      #expect(help.out.contains("Arguments") && help.out.contains("Example"))
      #expect(help.out.contains("As an MCP tool this is \"\(tool)\"."))
      // Help never runs the command.
      #expect(await harness.cli(["help"] + path).out == help.out)
    }
    #expect(await harness.meetings().count == 3)
  }

  @Test func groupsAndExtrasExplainThemselves() async throws {
    let group = await harness.cli("meetings")
    #expect(group.code == 0 && group.out.contains("meetings search") && !group.out.contains("actions list"))
    #expect(await harness.cli("meetings", "--help").out == group.out)
    for extra in ["mcp", "mcp-config", "doctor", "tools"] {
      let help = await harness.cli(extra, "--help")
      #expect(help.code == 0 && help.out.hasPrefix("wisper \(extra)"))
    }
    #expect(
      await harness.cli("mcp", "--help").out.contains(
        "claude mcp add open-wisper -- \"\(Harness.toolPath)\" mcp"
      )
    )
    let alias = await harness.cli("actions", "reopen", "--help")
    #expect(alias.out.hasPrefix("wisper actions reopen <action>\n"))
    #expect(alias.out.contains("wisper actions set-done <action> [--no-done]"))
  }

  @Test func version() async throws {
    #expect(await harness.cli("--version").out == "wisper \(WisperAgent.version)")
    #expect(await harness.cli("version").out == "wisper \(WisperAgent.version)")
  }

  @Test func helpNeverOpensTheLibrary() async throws {
    let opened = Lines()
    let agent = WisperAgent(
      library: {
        opened.append("opened")
        return InMemoryLibrary()
      }(),
      environment: WisperAgent.Environment(
        dataFolder: URL(fileURLWithPath: "/nowhere"),
        executablePath: "/nowhere/wisper",
        workingDirectory: URL(fileURLWithPath: "/nowhere"),
        openLink: { _ in },
        appIsRunning: { nil }
      )
    )
    let io = WisperAgent.IO(input: AsyncStream { $0.finish() }, output: { _ in }, error: { _ in })
    for arguments in [
      ["--help"], ["meetings", "list", "--help"], ["mcp-config"], ["tools"], ["--version"], ["nope"],
    ] {
      await agent.run(arguments, io: io)
    }
    #expect(opened.all.isEmpty)
    await agent.run(["meetings", "list"], io: io)
    await agent.run(["dictionary", "list"], io: io)
    #expect(opened.all.count == 1)
  }

  // MARK: Output

  @Test func textForPeople() async throws {
    let meeting = await harness.meetings()[0]
    let list = await harness.cli("meetings", "list")
    #expect(list.code == 0 && list.err.isEmpty)
    let lines = list.out.split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    #expect(lines[0].hasPrefix(String(meeting.id.uuidString.prefix(8))))
    #expect(lines[0].contains("2026-11-18 15:30") && lines[0].contains("31 min"))
    #expect(
      lines[0].contains("Weekly product sync") && lines[0].contains("#product")
        && lines[0].contains("(1 open)")
    )

    let shown = await harness.cli("meetings", "show", String(meeting.id.uuidString.prefix(8)))
    #expect(shown.out.contains("ID: \(meeting.id.uuidString)"))
    #expect(shown.out.contains("# Weekly product sync") && shown.out.contains("## Action items"))
    #expect(shown.out.contains("Transcript: 4 segments") && !shown.out.contains("Thanks for joining"))

    let actions = await harness.cli("actions", "list")
    #expect(
      actions.out.contains("[ ] \(meeting.notes!.actionItems[0].id.uuidString.prefix(8))  Check in with Sam")
    )
    #expect(actions.out.contains("(Alex)"))
  }

  @Test func jsonIsTheSameDataTheMCPServerReturns() async throws {
    let cases: [(cli: [String], tool: String, arguments: String)] = [
      (["meetings", "list", "--limit", "2"], "meetings_list", #"{"limit":2}"#),
      (["meetings", "get", "latest"], "meetings_get", #"{"meeting":"latest"}"#),
      (["meetings", "search", "pricing"], "meetings_search", #"{"query":"pricing"}"#),
      (
        ["meetings", "transcript", "latest", "--speaker", "me"], "meetings_transcript",
        #"{"meeting":"latest","speaker":"me"}"#
      ),
      (["actions", "list", "--status", "all"], "actions_list", #"{"status":"all"}"#),
      (["dictations", "list", "--limit=3"], "dictations_list", #"{"limit":3}"#),
      (["dictionary", "list"], "dictionary_list", "{}"),
      (["snippets", "list"], "snippets_list", "{}"),
      (["settings", "get"], "settings_get", "{}"),
      (["recording", "status"], "recording_status", "{}"),
    ]
    for item in cases {
      let cli = await harness.cli(item.cli + ["--json"])
      #expect(cli.code == 0 && cli.err.isEmpty)
      #expect(cli.json.exists, "\(item.cli) did not print JSON")
      let mcp = try await harness.call(item.tool, item.arguments)
      #expect(cli.json.canonical == mcp.data.canonical, "\(item.tool) differs between the two front ends")
    }
    // --json can sit anywhere.
    let early = await harness.cli("--json", "meetings", "list", "--limit", "2")
    #expect(early.json["returned"].int == 2)
  }

  @Test func toolsCommandMatchesTheServer() async throws {
    let cli = await harness.cli("tools", "--json")
    let mcp = try await harness.request("tools/list")["result"]["tools"]
    #expect(cli.json.canonical == mcp.canonical)
    let text = await harness.cli("tools")
    #expect(text.out.contains("wisper meetings get <meeting> [--include-transcript]"))
    #expect(text.out.contains("MCP tool: actions_set_done"))
    #expect(await harness.cli("tools", "--yaml").code == 2)
  }

  // MARK: Reading arguments

  @Test func flagsInEveryForm() async throws {
    #expect(await harness.cli("meetings", "list", "--limit", "1", "--json").json["returned"].int == 1)
    #expect(await harness.cli("meetings", "list", "--limit=1", "--json").json["returned"].int == 1)
    #expect(
      await harness.cli("meetings", "list", "--status", "ready", "--tag", "product", "--json").json["total"]
        .int == 1
    )
    // A choice can be given by its value alone.
    #expect(await harness.cli("meetings", "list", "--failed", "--json").json["total"].int == 0)
    #expect(await harness.cli("actions", "list", "--done", "--json").json["returned"].int == 1)
    #expect(
      await harness.cli("actions", "list", "--open", "--owner", "Alex", "--json").json["returned"].int == 2
    )
    // Switches.
    #expect(
      await harness.cli("meetings", "get", "latest", "--include-transcript", "--json").json["transcript"]
        .exists
    )
    #expect(!(await harness.cli("meetings", "get", "latest", "--json").json["transcript"].exists))
    #expect(await harness.cli("meetings", "export", "latest").out.contains("## Transcript"))
    #expect(
      !(await harness.cli("meetings", "export", "latest", "--no-include-transcript").out.contains(
        "## Transcript"
      ))
    )
    #expect(
      !(await harness.cli("meetings", "export", "latest", "--include-transcript=false").out.contains(
        "## Transcript"
      ))
    )
    // A positional argument can also be given by name.
    #expect(
      await harness.cli("meetings", "get", "--meeting", "latest", "--json").json["title"].string
        == "Weekly product sync"
    )
  }

  @Test func listsAndLooseWords() async throws {
    let tagged = await harness.cli(
      "meetings",
      "update",
      "latest",
      "--add-tags",
      "q4, launch",
      "--add-tags",
      "urgent",
      "--json"
    )
    #expect(tagged.json["tags"].strings == ["product", "q4", "launch", "urgent"])
    let replaced = await harness.cli("meetings", "update", "latest", "--tags=one,two", "--json")
    #expect(replaced.json["tags"].strings == ["one", "two"])

    // Words without quotes are read as one text.
    let search = await harness.cli("dictations", "search", "flat", "white", "--json")
    #expect(search.json["total"].int == 1)
    let added = await harness.cli(
      "actions",
      "add",
      "latest",
      "Send",
      "the",
      "deck",
      "--owner",
      "Alex",
      "--json"
    )
    #expect(added.json["text"].string == "Send the deck" && added.json["owner"].string == "Alex")

    // After "--" nothing is read as an option.
    let note = await harness.cli("meetings", "add-note", "latest", "--", "--json is not an option here")
    #expect(note.code == 0)
    #expect(await harness.meetings()[0].userNotes.hasSuffix("--json is not an option here"))
  }

  @Test func otherSpellingsOfACommand() async throws {
    let meeting = await harness.meetings()[0]
    let item = meeting.notes!.actionItems[0]
    let done = await harness.cli("actions", "done", String(item.id.uuidString.prefix(8)))
    #expect(done.code == 0 && done.out.contains("[x]"))
    #expect(await harness.library.meeting(meeting.id)?.notes?.actionItems[0].done == true)
    let reopened = await harness.cli("actions", "reopen", item.id.uuidString, "--json")
    #expect(reopened.json["done"].bool == false)
    let explicit = await harness.cli("actions", "set-done", item.id.uuidString, "--no-done", "--json")
    #expect(explicit.json["done"].bool == false)
    // An alias fixes its own argument: it cannot be turned around.
    #expect(await harness.cli("actions", "done", item.id.uuidString, "--no-done").code == 2)
    #expect(
      await harness.cli("actions", "edit", item.id.uuidString, "--owner", "Sam", "--json").json["owner"]
        .string == "Sam"
    )
  }

  @Test func writingCommandsChangeTheLibrary() async throws {
    #expect(await harness.cli("dictionary", "add", "Kubernetes").out.contains("Already there"))
    #expect(await harness.cli("dictionary", "add", "Grafana", "--replaces", "graph Anna").code == 0)
    #expect(await harness.library.words().first?.replaces == "graph Anna")
    #expect(await harness.cli("dictionary", "remove", "Grafana").code == 0)
    #expect(await harness.cli("snippets", "add", "my address", "1 Main Street").code == 0)
    #expect(await harness.library.snippets().first?.expansion == "1 Main Street")
    let third = await harness.meetings()[2]
    #expect(await harness.cli("meetings", "delete", third.id.uuidString).code == 0)
    #expect(await harness.meetings().count == 2)
  }

  // MARK: Errors

  @Test func mistakesInTheCommandExitWith2() async throws {
    let cases: [([String], String)] = [
      (["meeting", "list"], "Did you mean \"meetings\"?"),
      (["frobnicate"], "There is no command \"frobnicate\"."),
      (["meetings", "lst"], "Did you mean \"list\"?"),
      (["meetings", "list", "--colour", "red"], "\"--colour\" is not an option"),
      (["meetings", "list", "--limit"], "\"--limit\" needs a value."),
      (["meetings", "list", "--limit", "many"], "must be a whole number"),
      (["meetings", "list", "--limit", "9999"], "between 1 and 200"),
      (["meetings", "list", "--status", "asleep"], "must be one of"),
      (["meetings", "list", "extra"], "Too many arguments"),
      (["meetings", "get"], "\"meeting\" is required"),
      (["meetings", "get", "not an id"], "is not a meeting ID"),
      (["meetings", "delete", "latest"], "\"latest\" is not accepted"),
      (["meetings", "update", "latest"], "Nothing to change"),
      (["meetings", "transcript", "latest", "--from", "noon"], "could not be read as a time"),
      (["mcp", "extra"], "takes no arguments"),
      (["doctor", "extra"], "takes no arguments"),
    ]
    for (arguments, message) in cases {
      let outcome = await harness.cli(arguments)
      #expect(outcome.code == 2, "\(arguments)")
      #expect(outcome.out.isEmpty, "\(arguments) wrote to standard output")
      #expect(outcome.err.contains(message), "\(arguments): \(outcome.err)")
      #expect(outcome.err.hasPrefix("wisper: "))
      #expect(outcome.err.contains("--help"))
    }
    let usage = await harness.cli("meetings", "get")
    #expect(usage.err.contains("Usage: wisper meetings get <meeting> [--include-transcript]"))
    #expect(await harness.cli("meetings", "list", "--limit", "many", "--json").out.isEmpty)
  }

  @Test func thingsThatCannotBeDoneExitWith1() async throws {
    let cases: [([String], String)] = [
      (["meetings", "get", "ffffffff"], "No meeting has the ID"),
      (["actions", "done", "ffffffff"], "No action item has the ID"),
      (["dictionary", "remove", "Zeppelin"], "There is no dictionary word"),
      (["snippets", "add", "intro email", "x"], "already a snippet"),
      (["recording", "start"], "did not start recording"),
    ]
    for (arguments, message) in cases {
      let outcome = await harness.cli(arguments)
      #expect(outcome.code == 1, "\(arguments)")
      #expect(outcome.out.isEmpty)
      #expect(
        outcome.err.hasPrefix("wisper: ") && outcome.err.contains(message),
        "\(arguments): \(outcome.err)"
      )
    }
  }

  // MARK: Setup commands

  @Test func mcpConfigPrintsThePasteableSettings() async throws {
    let config = await harness.cli("mcp-config")
    #expect(config.code == 0)
    let server = config.json["mcpServers"]["open-wisper"]
    #expect(server["command"].string == Harness.toolPath)
    #expect(server["args"].strings == ["mcp"])
    #expect(!server["env"].exists)

    let moved = await Harness(homeOverride: "/tmp/other wisper").cli("mcp-config")
    #expect(moved.json["mcpServers"]["open-wisper"]["env"]["OPEN_WISPER_HOME"].string == "/tmp/other wisper")
  }

  @Test func doctorReportsTheState() async throws {
    let text = await harness.cli("doctor")
    #expect(text.code == 0)
    for part in [
      "Meetings:     3", "Action items: 2 open", "Dictations:   6", "Dictionary:   4 words",
      "Snippets:     2", "App:          running", harness.folder.path, "not there yet", "cannot read it",
    ] {
      #expect(text.out.contains(part), "doctor does not say: \(part)")
    }
    _ = try harness.makeFolder()
    defer { try? FileManager.default.removeItem(at: harness.folder) }
    harness.app.set(running: false)
    await harness.library.save(Meeting(title: "Live", startedAt: Harness.now, status: .recording))
    let json = await harness.cli("doctor", "--json").json
    #expect(json["meetings"].int == 4 && json["open_action_items"].int == 2 && json["dictations"].int == 6)
    #expect(json["dictionary_words"].int == 4 && json["snippets"].int == 2)
    #expect(json["recording"].bool == true && json["app_running"].bool == false)
    #expect(json["data_folder"].string == harness.folder.path && json["data_folder_exists"].bool == true)
    #expect(json["tool"].string == Harness.toolPath && json["version"].string == WisperAgent.version)
    #expect(json["mcp_protocol_versions"].strings.first == "2026-07-28")
  }

  // MARK: Documentation

  @Test func docsListTheToolsExactlyAsTheyAre() async throws {
    let page = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("docs/agents.md")
    let text = try String(contentsOf: page, encoding: .utf8)
    let start = try #require(text.range(of: "<!-- tools:start -->\n"))
    let end = try #require(text.range(of: "\n<!-- tools:end -->"))
    let written = String(text[start.upperBound..<end.lowerBound])
    let generated = await harness.cli("tools", "--markdown").out
    #expect(
      written == generated,
      "docs/agents.md is out of date. Paste the output of `wisper tools --markdown` between the tools markers."
    )
    for tool in await toolNames() { #expect(generated.contains("`\(tool)`")) }
  }
}
