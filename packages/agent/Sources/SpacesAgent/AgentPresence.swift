import Foundation
import SpacesDomain

/// Keeps this `spaces mcp` server's `AgentSession` in the library, so the app can show which
/// AI tool is connected and when it was last used.
///
/// The session is saved when the first request arrives, again when the client names itself
/// differently, at most every `interval` seconds while tools are used, and once more, marked
/// as stopped, by `end`. It holds the client's name for itself, times and tool names: never
/// anything the tool read or wrote.
actor AgentPresence {
  /// The shortest time between two saves caused by use.
  static let interval: TimeInterval = 30

  private let source: LazyLibrary
  private let pid: Int32
  private let log: @Sendable (String) -> Void
  private var session: AgentSession?
  private var savedAt = Date.distantPast
  private var pending: Task<Void, Never>?
  private var failed = false

  init(source: LazyLibrary, pid: Int32, log: @escaping @Sendable (String) -> Void) {
    self.source = source
    self.pid = pid
    self.log = log
  }

  /// A request arrived, with the client's `Implementation` (`clientInfo`) when it gave one.
  func noteClient(_ info: JSONValue?) async {
    let client = info.map(Self.client(from:))
    if var session {
      guard let client, client != session.client else { return }
      session.client = client
      self.session = session
    } else {
      session = AgentSession(pid: pid, client: client ?? AgentClient(name: ""))
    }
    await save()
  }

  /// The client used Spaces: called a tool (named `tool`), read a meeting or got a prompt.
  func noteUse(tool: String? = nil) async {
    if session == nil { session = AgentSession(pid: pid, client: AgentClient(name: "")) }
    session?.lastActiveAt = Date()
    if let tool { session?.lastTool = tool }
    let wait = Self.interval - Date().timeIntervalSince(savedAt)
    guard wait > 0 else {
      await save()
      return
    }
    guard pending == nil else { return }
    pending = Task { [weak self] in
      try? await Task.sleep(for: .seconds(wait))
      guard !Task.isCancelled else { return }
      await self?.savePending()
    }
  }

  /// The server is stopping: the session is saved as stopped now.
  func end() async {
    pending?.cancel()
    pending = nil
    guard session != nil else { return }
    session?.endedAt = Date()
    await save()
  }

  private func savePending() async {
    pending = nil
    await save()
  }

  private func save() async {
    guard let session else { return }
    savedAt = Date()
    do {
      try await source.library.save(session)
    } catch {
      // Saying who is connected must never get in the way of the tools themselves.
      guard !failed else { return }
      failed = true
      log("spaces mcp: could not note this connection in the data folder. \(error.localizedDescription)")
    }
  }

  /// The parts of a client's `Implementation` worth showing, each one short line of text.
  private static func client(from info: JSONValue) -> AgentClient {
    let fields = info.objectValue ?? [:]
    func text(_ key: String) -> String? {
      guard let value = fields[key]?.stringValue else { return nil }
      let line = String(
        String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
      )
      let tidy = String(line.trimmingCharacters(in: .whitespaces).prefix(80))
      return tidy.isEmpty ? nil : tidy
    }
    return AgentClient(name: text("name") ?? "", title: text("title"), version: text("version"))
  }
}
