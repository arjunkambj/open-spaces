import Foundation
import Testing
import WisperAgent
import WisperDomain

@Suite("MCP protocol")
struct MCPProtocolTests {
  let harness = Harness()

  // MARK: The older handshake

  @Test func handshakeThenRequests() async throws {
    let replies = try await harness.mcp(
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
      #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
      #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
      #"{"jsonrpc":"2.0","id":"three","method":"tools/list"}"#
    )
    // The notification gets no reply, so three requests give three replies.
    try #require(replies.count == 3)
    let hello = replies[0]
    #expect(hello["id"].int == 1)
    #expect(hello["result"]["protocolVersion"].string == "2025-06-18")
    #expect(hello["result"]["serverInfo"]["name"].string == "open-wisper")
    #expect(hello["result"]["serverInfo"]["version"].string == WisperAgent.version)
    #expect(hello["result"]["capabilities"]["tools"].exists)
    #expect(hello["result"]["capabilities"]["resources"].exists)
    #expect(hello["result"]["capabilities"]["prompts"].exists)
    #expect(hello["result"]["instructions"].string?.contains("meetings_list") == true)

    #expect(replies[1]["id"].int == 2)
    #expect(replies[1]["result"].keys.isEmpty)

    #expect(replies[2]["id"].string == "three")
    #expect(replies[2]["result"]["tools"].array.count >= 20)
    // Fields that only exist in the current revision are not sent to an older client.
    #expect(!replies[2]["result"]["resultType"].exists)
  }

  @Test func handshakeAnswersAnUnknownVersionWithOneItSpeaks() async throws {
    let replies = try await harness.mcp(
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{}}}"#
    )
    #expect(replies[0]["result"]["protocolVersion"].string == "2025-11-25")
  }

  @Test(arguments: ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
  func handshakeAcceptsEveryOlderVersion(version: String) async throws {
    let replies = try await harness.mcp(
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{}}}"#
    )
    #expect(replies[0]["result"]["protocolVersion"].string == version)
  }

  // MARK: The current revision

  @Test func discoverDescribesTheServer() async throws {
    let reply = try await harness.request("server/discover")
    let result = reply["result"]
    #expect(result["resultType"].string == "complete")
    #expect(result["supportedVersions"].strings == ["2026-07-28"])
    #expect(result["capabilities"]["tools"].exists)
    #expect(result["capabilities"]["prompts"].exists)
    #expect(result["capabilities"]["resources"]["subscribe"].bool == true)
    #expect(result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"].string == "open-wisper")
    #expect((result["ttlMs"].int ?? -1) >= 0)
    #expect(result["cacheScope"].string == "public")
    #expect(result["instructions"].string?.isEmpty == false)
  }

  @Test func requestsNeedNoHandshake() async throws {
    let reply = try await harness.request("tools/list")
    #expect(reply["result"]["resultType"].string == "complete")
    #expect(reply["result"]["tools"].array.count >= 20)
    #expect((reply["result"]["ttlMs"].int ?? -1) >= 0)
    #expect(reply["result"]["cacheScope"].string == "public")
    #expect(
      reply["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["version"].string == WisperAgent.version
    )
  }

  @Test func unsupportedVersionListsTheSupportedOnes() async throws {
    let replies = try await harness.mcp(
      #"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2030-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#
    )
    #expect(replies[0]["id"].int == 7)
    #expect(replies[0]["error"]["code"].int == -32022)
    #expect(replies[0]["error"]["data"]["requested"].string == "2030-01-01")
    #expect(replies[0]["error"]["data"]["supported"].strings == ["2026-07-28"])
  }

  @Test func missingClientCapabilitiesIsRejected() async throws {
    let replies = try await harness.mcp(
      #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
    )
    #expect(replies[0]["error"]["code"].int == -32602)
    #expect(replies[0]["error"]["message"].string?.contains("clientCapabilities") == true)
  }

  @Test func aRequestWithNoVersionAndNoHandshakeIsRejected() async throws {
    let replies = try await harness.mcp(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    #expect(replies[0]["error"]["code"].int == -32602)
    // The message tells the client both ways in.
    #expect(replies[0]["error"]["message"].string?.contains("initialize") == true)
    #expect(replies[0]["error"]["message"].string?.contains("2026-07-28") == true)
  }

  @Test func pingIsNotPartOfTheCurrentRevision() async throws {
    let reply = try await harness.request("ping")
    #expect(reply["error"]["code"].int == -32601)
  }

  // MARK: Bad input

  @Test func unknownMethod() async throws {
    let reply = try await harness.request("meetings/teleport")
    #expect(reply["error"]["code"].int == -32601)
    #expect(reply["error"]["message"].string?.contains("meetings/teleport") == true)
    #expect(reply["id"].int == 1)
  }

  @Test func malformedJSON() async throws {
    let replies = try await harness.mcp(#"{"jsonrpc":"2.0","id":1,"method":"#, "not json at all")
    #expect(replies.count == 2)
    for reply in replies {
      #expect(reply["jsonrpc"].string == "2.0")
      #expect(reply["error"]["code"].int == -32700)
      // No ID could be read, so the reply carries a null one.
      #expect(!reply["id"].exists)
      #expect(reply.canonical.contains(#""id":null"#))
    }
  }

  @Test func messagesThatAreNotRequests() async throws {
    let replies = try await harness.mcp(
      #"[1,2,3]"#,
      #""hello""#,
      #"{"jsonrpc":"2.0","id":1}"#,
      #"{"jsonrpc":"1.0","id":2,"method":"ping"}"#,
      #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
      #"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":[1]}"#
    )
    #expect(replies.map { $0["error"]["code"].int } == [-32600, -32600, -32600, -32600, -32600, -32602])
    #expect(replies[0]["error"]["message"].string?.contains("Batches") == true)
    #expect(replies[2]["id"].int == 1)
    #expect(replies[5]["id"].int == 3)
  }

  @Test func notificationsAndStrayRepliesGetNoAnswer() async throws {
    let lines = await harness.mcpLines([
      #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
      #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}"#,
      #"{"jsonrpc":"2.0","method":"something/unknown","params":{"x":1}}"#,
      #"{"jsonrpc":"2.0","method":"tools/list","params":"wrong"}"#,
      #"{"jsonrpc":"2.0","id":5,"result":{}}"#,
      "",
      "   ",
    ])
    #expect(lines.isEmpty)
  }

  @Test func everyReplyIsOneLineOfJSON() async throws {
    // Notes with line breaks and the Unicode line separators must not split a message.
    var meeting = await harness.meetings()[0]
    meeting.userNotes = "first line\nsecond line\u{2028}third\u{2029}fourth\ttabbed \"quoted\" \\ back"
    await harness.library.save(meeting)
    let lines = await harness.mcpLines([
      #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"meetings_get","arguments":{"meeting":"latest"},\#(Harness.meta)}}"#,
      #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"openwisper://meetings/latest",\#(Harness.meta)}}"#,
    ])
    try #require(lines.count == 2)
    for line in lines {
      #expect(!line.contains { $0.isNewline })
      #expect(throws: Never.self) { try JSON(parsing: line) }
    }
    let notes = try JSON(parsing: lines[0])["result"]["structuredContent"]["user_notes"].string
    #expect(notes == meeting.userNotes)
  }

  // MARK: Tools

  @Test func toolListIsWellFormed() async throws {
    let tools = try await harness.request("tools/list")["result"]["tools"].array
    #expect(tools.count == 24)
    var names = Set<String>()
    for tool in tools {
      let name = try #require(tool["name"].string)
      #expect(names.insert(name).inserted, "\(name) is listed twice")
      #expect(name.wholeMatch(of: /[a-z]+(_[a-z]+)+/) != nil, "\(name) is not a tidy tool name")
      #expect((tool["title"].string ?? "").count > 3)
      #expect((tool["description"].string ?? "").count >= 60, "\(name) needs a real description")

      let schema = tool["inputSchema"]
      #expect(schema["type"].string == "object")
      #expect(schema["additionalProperties"].bool == false)
      let properties = schema["properties"]
      for key in properties.keys {
        let property = properties[key]
        #expect(
          ["string", "integer", "boolean", "array"].contains(property["type"].string ?? ""),
          "\(name).\(key)"
        )
        #expect((property["description"].string ?? "").count >= 10, "\(name).\(key) needs a description")
        if property["type"].string == "array" { #expect(property["items"]["type"].string == "string") }
        if property["type"].string == "integer" {
          #expect(property["minimum"].int != nil && property["maximum"].int != nil)
        }
      }
      for required in schema["required"].strings {
        #expect(properties.keys.contains(required), "\(name) requires \(required) but does not define it")
      }

      let hints = tool["annotations"]
      #expect(hints["readOnlyHint"].bool != nil && hints["destructiveHint"].bool != nil)
      let readOnly = hints["readOnlyHint"].bool ?? false
      let destructive = hints["destructiveHint"].bool ?? true
      #expect(hints["idempotentHint"].bool != nil)
      // Only the export reaches outside the library: it can write a file anywhere the user can.
      #expect(hints["openWorldHint"].bool == (name == "meetings_export"), "\(name)")
      #expect(!(readOnly && destructive))
      // Names say what a tool does, so the hints must agree with them.
      if name.hasSuffix("_list") || name.hasSuffix("_get") || name.hasSuffix("_search")
        || name.hasSuffix("_status")
      {
        #expect(readOnly, "\(name) should be marked read-only")
      }
      if name.hasSuffix("_delete") || name.hasSuffix("_remove") {
        #expect(destructive, "\(name) should be marked destructive")
      }
    }
    for expected in [
      "meetings_list", "meetings_get", "meetings_transcript", "meetings_search", "meetings_add_note",
      "meetings_update", "meetings_export", "meetings_delete", "actions_list", "actions_add",
      "actions_set_done", "actions_update", "actions_remove", "recording_status", "recording_start",
      "recording_stop", "dictations_list", "dictionary_list", "dictionary_add", "dictionary_remove",
      "snippets_list", "snippets_add", "snippets_remove", "settings_get",
    ] {
      #expect(names.contains(expected), "\(expected) is missing")
    }
  }

  @Test func descriptionsOnlyNameToolsThatExist() async throws {
    let tools = try await harness.request("tools/list")["result"]["tools"].array
    let names = Set(tools.compactMap { $0["name"].string })
    let instructions = try await harness.request("server/discover")["result"]["instructions"].string ?? ""
    let prompts = try await harness.request("prompts/get", #""name":"open_action_items""#)["result"]
    let texts = tools.map(\.canonical) + [instructions, prompts.canonical]
    let mention = /\b(meetings|actions|recording|dictations|dictionary|snippets|settings)_[a-z_]+\b/
    var mentioned = Set<String>()
    for text in texts {
      for match in text.matches(of: mention) { mentioned.insert(String(match.0)) }
    }
    #expect(mentioned.isSubset(of: names), "unknown tools named: \(mentioned.subtracting(names).sorted())")
    #expect(mentioned.count >= 8)
  }

  @Test func toolListIsTheSameEveryTime() async throws {
    let first = try await harness.request("tools/list")["result"]["tools"]
    let second = try await harness.request("tools/list")["result"]["tools"]
    #expect(first.array.map { $0["name"].string } == second.array.map { $0["name"].string })
    #expect(first.canonical == second.canonical)
  }

  @Test func toolResultCarriesTheSameDataTwice() async throws {
    let reply = try await harness.call("meetings_list")
    #expect(!reply.isError)
    #expect(reply.reply["result"]["content"][0]["type"].string == "text")
    #expect(reply.reply["result"]["resultType"].string == "complete")
    // The text block is the structured content as JSON, for clients that only read text.
    #expect(try JSON(parsing: reply.text).canonical == reply.data.canonical)
  }

  @Test func unknownToolIsAProtocolError() async throws {
    let reply = try await harness.call("meetings_teleport")
    #expect(reply.reply["error"]["code"].int == -32602)
    #expect(reply.reply["error"]["message"].string == "Unknown tool: meetings_teleport")
  }

  @Test func badToolCallShapesAreProtocolErrors() async throws {
    let noName = try await harness.request("tools/call", #""arguments":{}"#)
    #expect(noName["error"]["code"].int == -32602)
    let badArguments = try await harness.request("tools/call", #""name":"meetings_list","arguments":[1]"#)
    #expect(badArguments["error"]["code"].int == -32602)
  }

  @Test func badArgumentsComeBackAsToolErrorsAModelCanFix() async throws {
    let unknown = try await harness.call("meetings_list", #"{"colour":"red"}"#)
    #expect(unknown.isError)
    #expect(unknown.text.contains("colour") && unknown.text.contains("limit"))
    #expect(!unknown.data.exists)

    let wrongType = try await harness.call("meetings_list", #"{"limit":"lots"}"#)
    #expect(wrongType.isError && wrongType.text.contains("whole number"))

    let outOfRange = try await harness.call("meetings_list", #"{"limit":0}"#)
    #expect(outOfRange.isError && outOfRange.text.contains("between 1 and 200"))

    let missing = try await harness.call("meetings_get")
    #expect(missing.isError && missing.text.contains("\"meeting\" is required"))

    let badChoice = try await harness.call("meetings_list", #"{"status":"sleeping"}"#)
    #expect(badChoice.isError && badChoice.text.contains("recording, processing, ready, failed"))

    let empty = try await harness.call("meetings_search", #"{"query":"  "}"#)
    #expect(empty.isError && empty.text.contains("must not be empty"))
  }

  @Test func argumentsAreReadKindly() async throws {
    // A number sent as text, a missing arguments object, and nulls for things left out.
    let asText = try await harness.call("meetings_list", #"{"limit":"1","since":null}"#)
    #expect(!asText.isError && asText.data["returned"].int == 1)
    let none = try await harness.request("tools/call", #""name":"settings_get""#)
    #expect(none["result"]["isError"].bool == false)
  }

  // MARK: Resources

  @Test func meetingsAreListedAsResources() async throws {
    let meetings = await harness.meetings()
    let result = try await harness.request("resources/list")["result"]
    #expect(result["resources"].array.count == 3)
    #expect(result["cacheScope"].string == "private")
    #expect(!result["nextCursor"].exists)
    let first = result["resources"][0]
    #expect(first["uri"].string == "openwisper://meetings/\(meetings[0].id.uuidString)")
    #expect(first["uri"].string == WisperLink.showMeeting(meetings[0].id).url.absoluteString)
    #expect(first["name"].string == "Weekly product sync")
    #expect(first["mimeType"].string == "text/markdown")
    #expect(first["description"].string?.contains("2026-11-18 15:30") == true)
    #expect(first["annotations"]["lastModified"].string == "2026-11-18T16:01:00+05:30")
  }

  @Test func resourceListComesInPages() async throws {
    let many = (0..<230).map { index in
      Meeting(
        title: "Meeting \(index)",
        startedAt: Harness.now.addingTimeInterval(-Double(index) * 3_600),
        status: .ready
      )
    }
    let harness = Harness(library: InMemoryLibrary(meetings: many))
    var seen: [String] = []
    var cursor: String?
    var pages = 0
    repeat {
      let result = try await harness.request("resources/list", cursor.map { #""cursor":"\#($0)""# } ?? "")[
        "result"
      ]
      seen += result["resources"].array.compactMap { $0["name"].string }
      cursor = result["nextCursor"].string
      pages += 1
    } while cursor != nil && pages < 10
    #expect(pages == 3)
    #expect(seen == many.map(\.title))

    let bad = try await harness.request("resources/list", #""cursor":"banana""#)
    #expect(bad["error"]["code"].int == -32602)
    let past = try await harness.request("resources/list", #""cursor":"5000""#)
    #expect(past["error"]["code"].int == -32602)
  }

  @Test func readingAMeetingGivesMarkdown() async throws {
    let meeting = await harness.meetings()[1]
    let uri = "openwisper://meetings/\(meeting.id.uuidString)"
    let result = try await harness.request("resources/read", #""uri":"\#(uri)""#)["result"]
    #expect(result["contents"].array.count == 1)
    #expect(result["contents"][0]["uri"].string == uri)
    #expect(result["contents"][0]["mimeType"].string == "text/markdown")
    #expect(result["contents"][0]["text"].string == meeting.markdown(timeZone: Harness.zone))
    #expect(result["cacheScope"].string == "private")
    #expect(result["ttlMs"].int == 0)

    let latest = try await harness.request("resources/read", #""uri":"openwisper://meetings/latest""#)[
      "result"
    ]
    #expect(latest["contents"][0]["text"].string?.hasPrefix("# Weekly product sync") == true)
  }

  @Test(arguments: [
    "openwisper://meetings/00000000-0000-0000-0000-000000000000", "openwisper://meetings/",
    "file:///etc/passwd",
    "openwisper://dictations/latest", "openwisper://meetings/latest/extra",
  ])
  func readingSomethingThatIsNotThere(uri: String) async throws {
    let reply = try await harness.request("resources/read", #""uri":"\#(uri)""#)
    #expect(reply["error"]["code"].int == -32602)
    #expect(reply["error"]["message"].string == "Resource not found")
    #expect(reply["error"]["data"]["uri"].string == uri)
    #expect(!reply["result"].exists)
  }

  @Test func resourceTemplateDescribesTheAddress() async throws {
    let result = try await harness.request("resources/templates/list")["result"]
    #expect(result["resourceTemplates"].array.count == 1)
    #expect(result["resourceTemplates"][0]["uriTemplate"].string == "openwisper://meetings/{id}")
    let missing = try await harness.request("resources/read")
    #expect(missing["error"]["code"].int == -32602)
  }

  // MARK: Prompts

  @Test func promptsAreListed() async throws {
    let prompts = try await harness.request("prompts/list")["result"]["prompts"].array
    #expect(
      prompts.map { $0["name"].string } == ["summarise_meeting", "open_action_items", "follow_up_email"]
    )
    for prompt in prompts {
      #expect((prompt["description"].string ?? "").count > 20)
      #expect(prompt["arguments"].array.allSatisfy { $0["required"].bool == false })
    }
  }

  @Test func summarisePromptAttachesTheLatestMeeting() async throws {
    let meeting = await harness.meetings()[0]
    let result = try await harness.request("prompts/get", #""name":"summarise_meeting""#)["result"]
    let messages = result["messages"].array
    try #require(messages.count == 2)
    #expect(messages[0]["role"].string == "user")
    #expect(messages[0]["content"]["type"].string == "text")
    // The request names the meeting by its date. Its title is in the attached document only.
    #expect(messages[0]["content"]["text"].string?.contains("2026-11-18 15:30") == true)
    #expect(messages[1]["content"]["type"].string == "resource")
    #expect(
      messages[1]["content"]["resource"]["uri"].string == "openwisper://meetings/\(meeting.id.uuidString)"
    )
    #expect(messages[1]["content"]["resource"]["text"].string?.contains("billing migration") == true)
    #expect(messages[1]["content"]["resource"]["text"].string?.hasPrefix("# Weekly product sync") == true)

    let other = await harness.meetings()[1]
    let chosen = try await harness.request(
      "prompts/get",
      #""name":"follow_up_email","arguments":{"meeting":"\#(other.id.uuidString.prefix(8))"}"#
    )["result"]
    #expect(chosen["messages"][0]["content"]["text"].string?.contains("2026-11-16") == true)
    #expect(
      chosen["messages"][1]["content"]["resource"]["text"].string?.hasPrefix("# Customer call with Northwind")
        == true
    )
  }

  @Test func actionItemsPromptPointsAtTheTool() async throws {
    let result = try await harness.request(
      "prompts/get",
      #""name":"open_action_items","arguments":{"owner":"Alex"}"#
    )["result"]
    #expect(result["messages"].array.count == 1)
    let text = result["messages"][0]["content"]["text"].string ?? ""
    #expect(text.contains("actions_list") && text.contains("Alex"))
  }

  @Test func promptErrors() async throws {
    let unknown = try await harness.request("prompts/get", #""name":"write_a_poem""#)
    #expect(unknown["error"]["code"].int == -32602)
    let badArgument = try await harness.request(
      "prompts/get",
      #""name":"summarise_meeting","arguments":{"mood":"happy"}"#
    )
    #expect(badArgument["error"]["code"].int == -32602)
    let noSuchMeeting = try await harness.request(
      "prompts/get",
      #""name":"summarise_meeting","arguments":{"meeting":"ffffffff"}"#
    )
    #expect(noSuchMeeting["error"]["code"].int == -32602)
    let empty = Harness(library: InMemoryLibrary())
    let nothing = try await empty.request("prompts/get", #""name":"summarise_meeting""#)
    #expect(nothing["error"]["message"].string == "There are no meetings yet.")
  }

  // MARK: Subscriptions

  @Test func subscriptionReportsChangedAndNewMeetings() async throws {
    let meeting = await harness.meetings()[0]
    let uri = "openwisper://meetings/\(meeting.id.uuidString)"
    let session = harness.session()
    session.send(
      #"{"jsonrpc":"2.0","id":"sub-1","method":"subscriptions/listen","params":{"notifications":{"resourcesListChanged":true,"toolsListChanged":true,"resourceSubscriptions":["\#(uri)","file:///nope"]},\#(Harness.meta)}}"#
    )
    let acknowledged = try await session.next()
    #expect(acknowledged["method"].string == "notifications/subscriptions/acknowledged")
    #expect(acknowledged["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].string == "sub-1")
    // Only what the server can really deliver is promised.
    #expect(acknowledged["params"]["notifications"]["resourcesListChanged"].bool == true)
    #expect(acknowledged["params"]["notifications"]["resourceSubscriptions"].strings == [uri])
    #expect(!acknowledged["params"]["notifications"]["toolsListChanged"].exists)
    #expect(!acknowledged["id"].exists)

    // A request on the same connection is still answered while the subscription is open.
    session.send(
      #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"meetings_add_note","arguments":{"meeting":"latest","text":"hello"},\#(Harness.meta)}}"#
    )
    var sawReply = false
    var sawUpdate = false
    for _ in 0..<2 {
      let message = try await session.next()
      if message["id"].int == 2 {
        sawReply = true
      } else {
        #expect(message["method"].string == "notifications/resources/updated")
        #expect(message["params"]["uri"].string == uri)
        #expect(message["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].string == "sub-1")
        sawUpdate = true
      }
    }
    #expect(sawReply && sawUpdate)

    await harness.library.save(Meeting(title: "Brand new", startedAt: Harness.now, status: .ready))
    let listChanged = try await session.next()
    #expect(listChanged["method"].string == "notifications/resources/list_changed")

    // After the client cancels, changes are no longer reported.
    session.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"sub-1"}}"#)
    session.send(
      #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"meetings_add_note","arguments":{"meeting":"\#(meeting.id.uuidString)","text":"again"},\#(Harness.meta)}}"#
    )
    let reply = try await session.next()
    #expect(reply["id"].int == 3)
    await session.close()
    #expect(session.out.all.count == 5)
  }

  @Test func subscriptionWithNothingToWatchIsStillAcknowledged() async throws {
    let lines = try await harness.mcp(
      #"{"jsonrpc":"2.0","id":9,"method":"subscriptions/listen","params":{"notifications":{"promptsListChanged":true},\#(Harness.meta)}}"#
    )
    #expect(lines.count == 1)
    #expect(lines[0]["method"].string == "notifications/subscriptions/acknowledged")
    #expect(lines[0]["params"]["notifications"].keys.isEmpty)
    #expect(lines[0]["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].int == 9)
  }
}
