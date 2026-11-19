import CryptoKit
import Foundation
import Testing
import WisperDomain

@testable import WisperAI

/// A pretend server for one test.
///
/// Each `Server` owns its own `URLSession`, and that session stamps every request with the
/// server's ID. `StubProtocol` uses the stamp to find the right server, so tests running at
/// the same time never see each other's requests.
final class Server: @unchecked Sendable {
  struct Request: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data
    var timeout: TimeInterval

    var path: String { url.path }

    func header(_ name: String) -> String? {
      headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    /// The body read as JSON.
    var json: [String: Any] {
      (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    /// The body read as an upload form.
    var form: Form { Form(body: body, contentType: header("Content-Type") ?? "") }
  }

  enum Answer: Sendable {
    case reply(status: Int, headers: [String: String] = [:], body: String)
    case fail(URLError.Code)
    /// Never answers, like a server that has stopped responding.
    case hang

    static func ok(_ body: String) -> Answer { .reply(status: 200, body: body) }

    /// An error the way OpenAI writes them.
    static func error(
      _ status: Int,
      _ message: String,
      param: String? = nil,
      code: String? = nil,
      headers: [String: String] = [:]
    ) -> Answer {
      var detail: [String: Any] = ["message": message, "type": "invalid_request_error"]
      if let param { detail["param"] = param }
      if let code { detail["code"] = code }
      let body = try! JSONSerialization.data(withJSONObject: ["error": detail])
      return .reply(status: status, headers: headers, body: String(decoding: body, as: UTF8.self))
    }
  }

  static let stamp = "X-Test-Server"
  private static let lock = NSLock()
  nonisolated(unsafe) private static var servers: [String: Server] = [:]

  static func find(_ id: String) -> Server? { lock.withLock { servers[id] } }

  let session: URLSession
  private let id = UUID().uuidString
  private let lock = NSLock()
  private var seen: [Request] = []
  private var waited: [TimeInterval] = []
  private let answer: @Sendable (Request, Int) -> Answer

  /// `answer` gets each request and its number, starting at 1.
  init(_ answer: @escaping @Sendable (Request, Int) -> Answer) {
    self.answer = answer
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    configuration.httpAdditionalHeaders = [Server.stamp: id]
    session = URLSession(configuration: configuration)
    Server.lock.withLock { Server.servers[id] = self }
  }

  /// Gives the answers in order, then keeps repeating the last one.
  convenience init(_ answers: Answer...) {
    self.init { _, number in answers[min(number, answers.count) - 1] }
  }

  deinit {
    Server.lock.withLock { _ = Server.servers.removeValue(forKey: id) }
    session.invalidateAndCancel()
  }

  var requests: [Request] { lock.withLock { seen } }
  /// The waits between retries, in seconds. Nothing really waits in tests.
  var pauses: [TimeInterval] { lock.withLock { waited } }

  fileprivate func receive(_ request: Request) -> Answer {
    let number = lock.withLock {
      seen.append(request)
      return seen.count
    }
    return answer(request, number)
  }

  /// An `OpenAI` that talks to this server. Leave `baseURL` out to pretend to be OpenAI itself.
  /// The key counts as saved for the server at `baseURL`, unless `savedFor` names another host.
  func openAI(key: String? = "sk-test-key", baseURL: String? = nil, savedFor: String? = nil) -> OpenAI {
    let host = savedFor ?? (try? APIServer(address: baseURL))?.host ?? APIServer.openAIHost
    return openAI(secrets: InMemorySecretStore(apiKey: key, host: host)) { baseURL }
  }

  /// `address` returns the text of the custom server address, as the settings hold it.
  func openAI(
    secrets: any SecretStore,
    address: @escaping @Sendable () async throws -> String? = { nil }
  ) -> OpenAI {
    OpenAI(secrets: secrets, address: address, session: session) { [weak self] seconds in
      try Task.checkCancellation()
      self?.lock.withLock { self?.waited.append(seconds) }
    }
  }

  /// The shared request code on its own, for the few things only it can show.
  func client(key: String? = "sk-test-key") -> Client {
    Client(
      secrets: InMemorySecretStore(apiKey: key),
      address: { nil },
      connections: Connections(fixed: session)
    ) { _ in }
  }
}

/// A real, tiny web server on this machine (127.0.0.1 only), for what a pretend one cannot
/// show: how the system's own networking treats a redirect.
final class LocalServer: @unchecked Sendable {
  struct Request: Sendable {
    /// `POST /v1/chat/completions`
    var line: String
    var headers: [String: String]
    var body: Data

    var path: String { line.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
  }

  let port: Int
  private let listener: Int32
  private let lock = NSLock()
  private var seen: [Request] = []
  private let answer: @Sendable (Request, Int) -> String

  /// `answer` gets each request and this server's port, and returns the whole reply, head and body.
  init(_ answer: @escaping @Sendable (Request, Int) -> String) throws {
    self.answer = answer
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw CocoaError(.fileReadUnknown) }
    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
    }
    var named = sockaddr_in()
    var namedLength = length
    let asked = withUnsafeMutablePointer(to: &named) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &namedLength) }
    }
    guard bound == 0, asked == 0, listen(listener, 8) == 0 else {
      close(listener)
      throw CocoaError(.fileReadUnknown)
    }
    self.listener = listener
    port = Int(UInt16(bigEndian: named.sin_port))
    Thread.detachNewThread { [weak self, listener] in
      while true {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        guard let self else {
          // The server is gone, and this was its goodbye: see `Listening.stop`.
          close(connection)
          close(listener)
          return
        }
        self.serve(connection)
      }
    }
  }

  deinit { Listening.stop(port: port) }

  var requests: [Request] { lock.withLock { seen } }

  /// A reply with a JSON body.
  static func ok(_ body: String) -> String {
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
      + "Connection: close\r\n\r\n" + body
  }

  /// A "go there instead" reply that asks for the same request to be sent again.
  static func redirect(to location: String) -> String {
    "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  }

  private func serve(_ connection: Int32) {
    defer { close(connection) }
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    let blank = Data("\r\n\r\n".utf8)
    var request: Request?
    while request == nil {
      let count = read(connection, &buffer, buffer.count)
      guard count > 0 else { return }
      received.append(buffer, count: count)
      guard let split = received.range(of: blank) else { continue }
      let lines = String(decoding: received[..<split.lowerBound], as: UTF8.self).components(
        separatedBy: "\r\n"
      )
      var headers: [String: String] = [:]
      for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(
          in: .whitespaces
        )
      }
      let body = received[split.upperBound...]
      guard body.count >= Int(headers["content-length"] ?? "0") ?? 0 else { continue }
      request = Request(line: lines.first ?? "", headers: headers, body: Data(body))
    }
    guard let request else { return }
    lock.withLock { seen.append(request) }
    let reply = Array(answer(request, port).utf8)
    var sent = 0
    while sent < reply.count {
      let count = reply[sent...].withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
      guard count > 0 else { return }
      sent += count
    }
  }
}

/// How the small servers in this file shut down.
///
/// A socket is known by a number, and the system hands a closed socket's number to the next
/// one opened, which in a test run is some other test's. So a socket is only ever closed by
/// the thread that is using it. A server that goes away does not close its listening socket
/// from outside: it knocks on its own door, and the thread waiting there finds the server
/// gone and closes up itself.
enum Listening {
  static func stop(port: Int) {
    let knock = socket(AF_INET, SOCK_STREAM, 0)
    guard knock >= 0 else { return }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(knock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    close(knock)
  }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let id = request.value(forHTTPHeaderField: Server.stamp), let server = Server.find(id),
      let url = request.url
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    var headers = request.allHTTPHeaderFields ?? [:]
    headers[Server.stamp] = nil
    let seen = Server.Request(
      method: request.httpMethod ?? "",
      url: url,
      headers: headers,
      body: request.httpBody ?? StubProtocol.read(request.httpBodyStream),
      timeout: request.timeoutInterval
    )
    switch server.receive(seen) {
    case .hang:
      break
    case .fail(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case .reply(let status, let headers, let body):
      let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}

  private static func read(_ stream: InputStream?) -> Data {
    guard let stream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

/// An upload form (`multipart/form-data`) taken apart again.
struct Form {
  struct Part {
    var name: String
    var fileName: String?
    var contentType: String?
    var data: Data
    var text: String { String(decoding: data, as: UTF8.self) }
  }

  var parts: [Part] = []

  init(body: Data, contentType: String) {
    guard let marker = contentType.range(of: "boundary=") else { return }
    let boundary = Data("--\(contentType[marker.upperBound...])".utf8)
    let blank = Data("\r\n\r\n".utf8)
    var cursor = body.startIndex
    while let start = body.range(of: boundary, in: cursor..<body.endIndex),
      let end = body.range(of: boundary, in: start.upperBound..<body.endIndex)
    {
      cursor = end.lowerBound
      // Between two boundaries: "\r\n" + headers + blank line + content + "\r\n".
      let section = body[(start.upperBound + 2)..<(end.lowerBound - 2)]
      guard let split = section.range(of: blank) else { continue }
      let head = String(decoding: section[section.startIndex..<split.lowerBound], as: UTF8.self)
      func quoted(_ key: String) -> String? {
        guard let from = head.range(of: "\(key)=\"") else { return nil }
        return head[from.upperBound...].split(separator: "\"", omittingEmptySubsequences: false).first.map(
          String.init
        )
      }
      let type = head.components(separatedBy: "\r\n").first { $0.hasPrefix("Content-Type: ") }
      parts.append(
        Part(
          name: quoted(" name") ?? "",
          fileName: quoted("filename"),
          contentType: type.map { String($0.dropFirst("Content-Type: ".count)) },
          data: Data(section[split.upperBound...])
        )
      )
    }
  }

  var names: [String] { parts.map(\.name) }
  func values(_ name: String) -> [String] { parts.filter { $0.name == name }.map(\.text) }
  func value(_ name: String) -> String? { values(name).first }
  var file: Part? { parts.first { $0.name == "file" } }
}

/// Audio files for tests, deleted when the value goes away.
final class Recordings: @unchecked Sendable {
  let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-wisper-ai-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: folder) }

  /// A file with the given bytes. Not real audio, which is fine for a pretend server.
  func file(_ name: String = "clip.m4a", bytes: Data = Data("pretend audio".utf8)) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
  }

  /// A real one-second WAV file: a 440 Hz tone at `level` (0 is silence, 1 is full volume).
  func wav(_ name: String, level: Double) throws -> URL {
    let rate = 16_000
    var samples = Data(capacity: rate * 2)
    for index in 0..<rate {
      let value = Int16((sin(2 * .pi * 440 * Double(index) / Double(rate)) * level * 32_767).rounded())
      withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
    }
    func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
      withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
    var data = Data("RIFF".utf8) + bytes(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8)
    data += bytes(UInt32(16)) + bytes(UInt16(1)) + bytes(UInt16(1)) + bytes(UInt32(rate))
    data += bytes(UInt32(rate * 2)) + bytes(UInt16(2)) + bytes(UInt16(16))
    data += Data("data".utf8) + bytes(UInt32(samples.count)) + samples
    return try file(name, bytes: data)
  }
}

/// Runs `work` and returns the `WisperError` it throws.
func wisperError(
  _ work: () async throws -> Void,
  sourceLocation: SourceLocation = #_sourceLocation
) async -> WisperError? {
  do {
    try await work()
    Issue.record("Expected an error, but the call succeeded.", sourceLocation: sourceLocation)
  } catch let error as WisperError {
    return error
  } catch {
    Issue.record("Expected a WisperError, got \(type(of: error)).", sourceLocation: sourceLocation)
  }
  return nil
}

/// A real web server on this machine (127.0.0.1 only) that keeps connections open and can
/// fall silent on one, for what only real connections can show: a request that never gets an
/// answer, and which connection its retry travels on.
final class QuietServer: @unchecked Sendable {
  enum Reply: Sendable {
    /// The whole reply, head and body. The connection stays open for the next request.
    case answer(String)
    /// Says nothing and keeps the connection open, like a connection that has died quietly.
    case silence
  }

  struct Seen: Sendable {
    var request: LocalServer.Request
    /// Which connection carried it: 1 for the first connection a request arrived on. (A
    /// connection that was opened but never used has no number.)
    var connection: Int
    var method: String { request.line.split(separator: " ").first.map(String.init) ?? "" }
  }

  let port: Int
  private let listener: Int32
  private let lock = NSLock()
  private var seen: [Seen] = []
  private var used = 0
  private let reply: @Sendable (Seen) -> Reply

  init(_ reply: @escaping @Sendable (Seen) -> Reply) throws {
    self.reply = reply
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw CocoaError(.fileReadUnknown) }
    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
    }
    var named = sockaddr_in()
    var namedLength = length
    let asked = withUnsafeMutablePointer(to: &named) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &namedLength) }
    }
    guard bound == 0, asked == 0, listen(listener, 16) == 0 else {
      close(listener)
      throw CocoaError(.fileReadUnknown)
    }
    self.listener = listener
    port = Int(UInt16(bigEndian: named.sin_port))
    Thread.detachNewThread { [weak self, listener] in
      while true {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        guard let self else {
          close(connection)
          close(listener)
          return
        }
        Thread.detachNewThread { [weak self] in self?.serve(connection) }
      }
    }
  }

  // Each connection is closed by the thread that serves it, when its client lets go.
  deinit { Listening.stop(port: port) }

  var address: String { "http://127.0.0.1:\(port)/v1" }
  var requests: [Seen] { lock.withLock { seen } }
  /// How many connections carried a request.
  var connections: Int { lock.withLock { used } }

  static func ok(_ body: String) -> Reply {
    .answer(
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
    )
  }

  /// "Who are you?", with no body: what a server says to a question that carries no key.
  static let unauthorized = Reply.answer("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")

  private func serve(_ connection: Int32) {
    defer { close(connection) }
    var number: Int?
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    let blank = Data("\r\n\r\n".utf8)
    var silent = false
    while true {
      // One whole request, if it has arrived.
      if !silent, let split = received.range(of: blank) {
        let lines = String(decoding: received[..<split.lowerBound], as: UTF8.self).components(
          separatedBy: "\r\n"
        )
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
          guard let colon = line.firstIndex(of: ":") else { continue }
          headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(
            in: .whitespaces
          )
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        if received.distance(from: split.upperBound, to: received.endIndex) >= length {
          let end = received.index(split.upperBound, offsetBy: length)
          let request = LocalServer.Request(
            line: lines.first ?? "",
            headers: headers,
            body: Data(received[split.upperBound..<end])
          )
          received = Data(received[end...])
          let seen = lock.withLock { () -> Seen in
            if number == nil {
              used += 1
              number = used
            }
            let seen = Seen(request: request, connection: number ?? 0)
            self.seen.append(seen)
            return seen
          }
          switch reply(seen) {
          case .silence:
            silent = true
          case .answer(let text):
            let bytes = Array(text.utf8)
            var sent = 0
            while sent < bytes.count {
              let count = bytes[sent...].withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
              guard count > 0 else { return }
              sent += count
            }
          }
          continue
        }
      }
      let count = read(connection, &buffer, buffer.count)
      guard count > 0 else { return }
      received.append(buffer, count: count)
    }
  }
}

/// A real WebSocket server on this machine (127.0.0.1 only) that plays the part of the
/// realtime API: it takes the handshake, then hands every message to `script`.
final class SocketServer: @unchecked Sendable {
  /// One client, as the script sees it.
  final class Peer: @unchecked Sendable {
    fileprivate let connection: Int32
    fileprivate init(_ connection: Int32) { self.connection = connection }

    /// Sends one text message.
    func say(_ text: String) {
      let payload = Array(text.utf8)
      var frame: [UInt8] = [0x81]
      if payload.count < 126 {
        frame.append(UInt8(payload.count))
      } else if payload.count < 65_536 {
        frame += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
      } else {
        frame.append(127)
        for shift in stride(from: 56, through: 0, by: -8) {
          frame.append(UInt8((payload.count >> shift) & 0xFF))
        }
      }
      frame += payload
      SocketServer.write(frame, to: connection)
    }

    /// Sends one event the way the API writes them.
    func say(_ event: [String: Any]) {
      say(String(decoding: (try? JSONSerialization.data(withJSONObject: event)) ?? Data(), as: UTF8.self))
    }

    /// Drops the connection without a goodbye.
    func hangUp() { shutdown(connection, SHUT_RDWR) }
  }

  let port: Int
  private let listener: Int32
  private let lock = NSLock()
  private var heads: [[String: String]] = []
  private var lines: [String] = []
  private var got: [String] = []
  private let accepts: Bool
  private let script: @Sendable (_ message: [String: Any], _ peer: Peer) -> Void

  /// - Parameters:
  ///   - accepts: Whether the handshake is taken. When not, the server answers "404".
  ///   - script: Gets each message the client sends, read as JSON.
  init(accepts: Bool = true, _ script: @escaping @Sendable (_ message: [String: Any], _ peer: Peer) -> Void)
    throws
  {
    self.accepts = accepts
    self.script = script
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw CocoaError(.fileReadUnknown) }
    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
    }
    var named = sockaddr_in()
    var namedLength = length
    let asked = withUnsafeMutablePointer(to: &named) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &namedLength) }
    }
    guard bound == 0, asked == 0, listen(listener, 16) == 0 else {
      close(listener)
      throw CocoaError(.fileReadUnknown)
    }
    self.listener = listener
    port = Int(UInt16(bigEndian: named.sin_port))
    Thread.detachNewThread { [weak self, listener] in
      while true {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        guard let self else {
          close(connection)
          close(listener)
          return
        }
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        Thread.detachNewThread { [weak self] in self?.serve(connection) }
      }
    }
  }

  // Each connection is closed by the thread that serves it.
  deinit { Listening.stop(port: port) }

  var address: String { "http://127.0.0.1:\(port)/v1" }
  /// The headers of each handshake, names in lower case.
  var handshakes: [[String: String]] { lock.withLock { heads } }
  /// The first line of each handshake: `GET /v1/realtime?intent=transcription HTTP/1.1`.
  var requestLines: [String] { lock.withLock { lines } }
  /// Every message the clients sent, as text.
  var messages: [String] { lock.withLock { got } }
  /// The `type` of every message the clients sent.
  var types: [String] { events.compactMap { $0["type"] as? String } }
  var events: [[String: Any]] {
    messages.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
  }

  /// All the sound the clients appended, decoded: 16-bit samples.
  var sound: [Int16] {
    var samples: [Int16] = []
    for event in events where event["type"] as? String == "input_audio_buffer.append" {
      guard let data = Data(base64Encoded: event["audio"] as? String ?? "") else { continue }
      data.withUnsafeBytes { raw in
        for index in stride(from: 0, to: raw.count - 1, by: 2) {
          samples.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: Int16.self)))
        }
      }
    }
    return samples
  }

  fileprivate static func write(_ bytes: [UInt8], to connection: Int32) {
    var sent = 0
    while sent < bytes.count {
      let count = bytes[sent...].withUnsafeBytes { Darwin.write(connection, $0.baseAddress, $0.count) }
      guard count > 0 else { return }
      sent += count
    }
  }

  private func serve(_ connection: Int32) {
    defer { close(connection) }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
    /// Reads until `buffer` holds `count` bytes. False when the client went away.
    func fill(_ count: Int) -> Bool {
      while buffer.count < count {
        let got = read(connection, &chunk, chunk.count)
        guard got > 0 else { return false }
        buffer.append(chunk, count: got)
      }
      return true
    }
    func take(_ count: Int) -> [UInt8]? {
      guard fill(count) else { return nil }
      let bytes = [UInt8](buffer.prefix(count))
      buffer = Data(buffer.dropFirst(count))
      return bytes
    }

    // The handshake.
    let blank = Data("\r\n\r\n".utf8)
    while buffer.range(of: blank) == nil {
      guard fill(buffer.count + 1) else { return }
    }
    guard let split = buffer.range(of: blank) else { return }
    let head = String(decoding: buffer[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    buffer = Data(buffer[split.upperBound...])
    var headers: [String: String] = [:]
    for line in head.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(
        in: .whitespaces
      )
    }
    lock.withLock {
      heads.append(headers)
      lines.append(head.first ?? "")
    }
    guard accepts, let key = headers["sec-websocket-key"] else {
      SocketServer.write(
        Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
        to: connection
      )
      return
    }
    let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
      .base64EncodedString()
    let reply =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
    SocketServer.write(Array(reply.utf8), to: connection)

    // Messages.
    let peer = Peer(connection)
    var message: [UInt8] = []
    while true {
      guard let start = take(2) else { return }
      let last = start[0] & 0x80 != 0
      let kind = start[0] & 0x0F
      var length = Int(start[1] & 0x7F)
      if length == 126 {
        guard let more = take(2) else { return }
        length = Int(more[0]) << 8 | Int(more[1])
      } else if length == 127 {
        guard let more = take(8) else { return }
        length = more.reduce(0) { $0 << 8 | Int($1) }
      }
      var mask: [UInt8] = [0, 0, 0, 0]
      if start[1] & 0x80 != 0 {
        guard let key = take(4) else { return }
        mask = key
      }
      guard var payload = take(length) else { return }
      for index in payload.indices { payload[index] ^= mask[index % 4] }
      switch kind {
      case 0x8:
        // Goodbye: say it back and leave.
        SocketServer.write([0x88, 0x00], to: connection)
        return
      case 0x9:
        SocketServer.write([0x8A, UInt8(min(payload.count, 125))] + payload.prefix(125), to: connection)
      case 0x0, 0x1:
        message += payload
        guard last else { continue }
        let text = String(decoding: message, as: UTF8.self)
        message = []
        lock.withLock { got.append(text) }
        if let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
          script(json, peer)
        }
      default:
        continue
      }
    }
  }
}
