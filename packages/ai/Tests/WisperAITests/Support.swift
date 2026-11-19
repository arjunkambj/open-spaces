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
  func openAI(key: String? = "sk-test-key", baseURL: String? = nil) -> OpenAI {
    openAI(secrets: InMemorySecretStore(apiKey: key)) { baseURL.flatMap(URL.init(string:)) }
  }

  func openAI(secrets: any SecretStore, baseURL: @escaping @Sendable () async -> URL? = { nil }) -> OpenAI {
    OpenAI(secrets: secrets, baseURL: baseURL, session: session) { [weak self] seconds in
      try Task.checkCancellation()
      self?.lock.withLock { self?.waited.append(seconds) }
    }
  }

  /// The shared request code on its own, for the few things only it can show.
  func client(key: String? = "sk-test-key") -> Client {
    Client(secrets: InMemorySecretStore(apiKey: key), baseURL: { nil }, session: session) { _ in }
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
