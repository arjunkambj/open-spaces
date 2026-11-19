import Foundation
import Testing
import WisperAgent
import WisperDomain

/// A parsed JSON value that is easy to dig into: `reply["result"]["tools"][0]["name"].string`.
struct JSON: @unchecked Sendable, CustomStringConvertible {
  let value: Any?

  init(_ value: Any?) { self.value = value is NSNull ? nil : value }

  init(parsing text: String) throws {
    self.init(try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
  }

  subscript(key: String) -> JSON { JSON((value as? [String: Any])?[key]) }

  subscript(index: Int) -> JSON {
    guard let items = value as? [Any], items.indices.contains(index) else { return JSON(nil) }
    return JSON(items[index])
  }

  var exists: Bool { value != nil }
  var string: String? { value as? String }
  var int: Int? {
    (value as? NSNumber).flatMap { $0 === kCFBooleanTrue || $0 === kCFBooleanFalse ? nil : $0.intValue }
  }
  var bool: Bool? {
    (value as? NSNumber).flatMap { $0 === kCFBooleanTrue ? true : ($0 === kCFBooleanFalse ? false : nil) }
  }
  var array: [JSON] { (value as? [Any] ?? []).map(JSON.init) }
  var keys: [String] { (value as? [String: Any]).map { Array($0.keys).sorted() } ?? [] }
  var strings: [String] { array.compactMap(\.string) }

  /// The value written back out with sorted keys, for comparing two values.
  var canonical: String {
    guard let value else { return "null" }
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "?"
  }

  var description: String { canonical }
}

/// Collects lines as they are written and lets a test wait for the next one.
final class Lines: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  private var read = 0

  func append(_ line: String) { lock.withLock { stored.append(line) } }
  var all: [String] { lock.withLock { stored } }
  var text: String { all.joined(separator: "\n") }

  /// The next line not yet handed out, waiting up to two seconds for it.
  func next() async -> String? {
    for _ in 0..<400 {
      let line: String? = lock.withLock {
        guard read < stored.count else { return nil }
        read += 1
        return stored[read - 1]
      }
      if let line { return line }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
  }
}

/// What a command printed and how it ended.
struct Outcome {
  var code: Int32
  var out: String
  var err: String

  var json: JSON { (try? JSON(parsing: out)) ?? JSON(nil) }
}

/// What a tool call over MCP came back with.
struct ToolReply {
  var reply: JSON
  var isError: Bool { reply["result"]["isError"].bool ?? false }
  var data: JSON { reply["result"]["structuredContent"] }
  var text: String { reply["result"]["content"][0]["text"].string ?? "" }
}

/// Stands in for the Open Wisper app: remembers the links it was sent and can act on them.
final class FakeApp: @unchecked Sendable {
  private let lock = NSLock()
  private var opened: [URL] = []
  private var running: Bool? = true
  private var answer: (@Sendable (WisperLink) async -> Void)?

  var links: [WisperLink] { lock.withLock { opened.compactMap(WisperLink.init) } }
  /// The addresses exactly as they were opened, with anything the tool attached to them.
  var urls: [URL] { lock.withLock { opened } }

  func set(running: Bool?) { lock.withLock { self.running = running } }
  func onLink(_ answer: @escaping @Sendable (WisperLink) async -> Void) {
    lock.withLock { self.answer = answer }
  }

  func open(_ url: URL) async {
    let answer = lock.withLock {
      opened.append(url)
      return self.answer
    }
    if let link = WisperLink(url) { await answer?(link) }
  }

  var isRunning: Bool? { lock.withLock { running } }
}

/// One library, one agent, and the ways a test talks to it.
struct Harness: Sendable {
  /// The moment every test runs at: 2026-11-19 12:00 UTC, which is 17:30 in the test time zone.
  static let now = Date(timeIntervalSince1970: 1_795_089_600)
  static let zone = TimeZone(secondsFromGMT: 5 * 3_600 + 1_800)!
  static let toolPath = "/Applications/Open Wisper.app/Contents/MacOS/wisper"

  static let version = "io.modelcontextprotocol/protocolVersion"
  static let meta =
    #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

  let library: InMemoryLibrary
  let app = FakeApp()
  /// A scratch folder: the one the tool was "started in". Not created until a test asks.
  let folder: URL
  /// Where the tool believes the library's files are. Inside `folder`, and not created
  /// until something needs it.
  let dataFolder: URL
  let agent: WisperAgent

  init(library: InMemoryLibrary? = nil, homeOverride: String? = nil, dataFolder: URL? = nil) {
    let library = library ?? SampleData.library(now: Harness.now)
    self.library = library
    let app = app
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("wisper-agent-tests-\(UUID().uuidString)", isDirectory: true)
    self.folder = folder
    let dataFolder = dataFolder ?? folder.appendingPathComponent("Open Wisper", isDirectory: true)
    self.dataFolder = dataFolder
    agent = WisperAgent(
      library: library,
      environment: WisperAgent.Environment(
        now: { Harness.now },
        timeZone: Harness.zone,
        dataFolder: dataFolder,
        homeOverride: homeOverride,
        executablePath: Harness.toolPath,
        workingDirectory: folder,
        openLink: { await app.open($0) },
        appIsRunning: { app.isRunning },
        appWait: .milliseconds(400)
      )
    )
  }

  /// Creates the scratch folder and returns it.
  func makeFolder() throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// Creates the data folder (and the scratch folder around it) and returns it.
  func makeDataFolder() throws -> URL {
    try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
    return dataFolder
  }

  /// Removes everything a test left on disk.
  func cleanUp() { try? FileManager.default.removeItem(at: folder) }

  /// The path with every symbolic link followed, the way the tool reports where it saved a file.
  static func real(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  // MARK: Command line

  func cli(_ arguments: String...) async -> Outcome { await cli(arguments) }

  func cli(_ arguments: [String]) async -> Outcome {
    let out = Lines()
    let err = Lines()
    let io = WisperAgent.IO(
      input: AsyncStream { $0.finish() },
      output: { out.append($0) },
      error: { err.append($0) }
    )
    let code = await agent.run(arguments, io: io)
    return Outcome(code: code, out: out.text, err: err.text)
  }

  // MARK: MCP

  /// Sends the lines to `wisper mcp` and returns every line it wrote back.
  func mcpLines(_ lines: [String]) async -> [String] {
    let out = Lines()
    let io = WisperAgent.IO(
      input: AsyncStream { continuation in
        for line in lines { continuation.yield(line) }
        continuation.finish()
      },
      output: { out.append($0) },
      error: { _ in }
    )
    await agent.run(["mcp"], io: io)
    return out.all
  }

  func mcp(_ lines: String...) async throws -> [JSON] {
    try await mcpLines(lines).map(JSON.init(parsing:))
  }

  /// One request in the current protocol revision. `params` is the inside of the params object.
  func request(_ method: String, _ params: String = "") async throws -> JSON {
    let body = params.isEmpty ? Harness.meta : "\(params),\(Harness.meta)"
    let replies = try await mcp(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{\#(body)}}"#)
    try #require(replies.count == 1)
    return replies[0]
  }

  /// Calls a tool over MCP. `arguments` is a JSON object as text.
  func call(_ tool: String, _ arguments: String = "{}") async throws -> ToolReply {
    ToolReply(reply: try await request("tools/call", #""name":"\#(tool)","arguments":\#(arguments)"#))
  }

  /// The sample meetings, newest first: the product sync, the customer call, the 1:1.
  func meetings() async -> [Meeting] { await library.meetings(search: nil) }

  /// A live MCP session for tests that need to act between messages.
  func session() -> Session {
    let (input, feed) = AsyncStream.makeStream(of: String.self)
    let out = Lines()
    let io = WisperAgent.IO(input: input, output: { out.append($0) }, error: { _ in })
    let agent = agent
    let task = Task { _ = await agent.run(["mcp"], io: io) }
    return Session(feed: feed, out: out, task: task)
  }

  struct Session: Sendable {
    let feed: AsyncStream<String>.Continuation
    let out: Lines
    let task: Task<Void, Never>

    func send(_ line: String) { feed.yield(line) }

    func next() async throws -> JSON {
      let line = try #require(await out.next(), "the server wrote nothing")
      return try JSON(parsing: line)
    }

    /// Ends the input and waits for the server to stop.
    func close() async {
      feed.finish()
      await task.value
    }
  }
}
