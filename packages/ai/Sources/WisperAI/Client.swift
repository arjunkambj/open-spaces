import Foundation
import WisperDomain

/// Sends one request to the user's server and brings back the reply body.
///
/// Everything the two adapters share lives here: where a request goes (the
/// rule itself is `APIServer`), the key, timeouts, retries, turning failures
/// into `WisperError`, and leaving out optional settings a server does not accept.
struct Client: Sendable {
  private let secrets: any SecretStore
  private let address: @Sendable () async throws -> String?
  private let session: URLSession
  private let pause: @Sendable (TimeInterval) async throws -> Void
  private let memory = Memory()

  /// - Parameter address: the text of the custom server address, or `nil` for OpenAI itself.
  init(
    secrets: any SecretStore,
    address: @escaping @Sendable () async throws -> String?,
    session: URLSession,
    pause: @escaping @Sendable (TimeInterval) async throws -> Void
  ) {
    self.secrets = secrets
    self.address = address
    self.session = session
    self.pause = pause
  }

  // MARK: Interface

  /// One request, described without the server address or the key.
  struct Call: Sendable {
    var method: String
    /// Endpoint under the API folder, e.g. `chat/completions`.
    var path: String
    var body: Body = .none
    /// Longest silence allowed on the connection, in seconds.
    var idle: TimeInterval

    enum Body: Sendable {
      case none
      case json(Data)
      /// A body already written to a file. The client deletes the file once it has been sent.
      case file(URL, contentType: String)
    }
  }

  enum Key: Sendable {
    /// The key in the secret store.
    case stored
    /// A key the user is trying out.
    case given(String)
  }

  /// Sends the request `build` describes and returns the reply body.
  ///
  /// - Parameters:
  ///   - scope: Names what the optional settings belong to (the model, say), so a setting the
  ///     server refused once is left out of later requests in the same scope.
  ///   - optional: Names of settings the request can do without. When the server refuses one by
  ///     name, the request is built again without it: `build` receives the names to leave out.
  ///   - budget: Seconds the whole call may take, retries included.
  /// - Throws: `WisperError`, or `CancellationError`.
  func send(
    scope: String = "",
    optional: Set<String> = [],
    key: Key = .stored,
    budget: TimeInterval,
    _ build: @escaping @Sendable (_ leftOut: Set<String>) async throws -> Call
  ) async throws -> Data {
    let server = try await resolve(key)
    let scope = "\(server.root.absoluteString) \(scope)"
    return try await withDeadline(budget) {
      var leftOut = await memory.refused(in: scope).intersection(optional)
      while true {
        do {
          let data = try await deliver(try await build(leftOut), to: server)
          await memory.remember(leftOut, in: scope)
          return data
        } catch let refusal as Refusal {
          guard let name = refusal.refusedSetting(among: optional.subtracting(leftOut)) else {
            throw refusal.asWisperError(hiding: server.key)
          }
          leftOut.insert(name)
        } catch WisperError.invalidAPIKey where server.key == nil {
          // No key was sent (none is saved for this server), so none was turned down:
          // the server wants one.
          throw WisperError.missingAPIKey
        }
      }
    }
  }

  /// Whether requests go to OpenAI itself rather than to a server the user set.
  func usesOpenAI() async -> Bool {
    (try? await server())?.isOpenAI ?? false
  }

  // MARK: Where and who

  private struct Server: Sendable {
    /// The folder that holds the API, without a trailing slash.
    var root: URL
    var key: String?
  }

  /// The server the settings name right now. An address that is set but unusable is an
  /// error: it must never quietly mean OpenAI.
  private func server() async throws -> APIServer {
    do {
      return try APIServer(address: try await address())
    } catch let error as WisperError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw WisperError.storage("the server address could not be read")
    }
  }

  private func resolve(_ key: Key) async throws -> Server {
    let server = try await server()
    let raw: String?
    switch key {
    case .given(let value):
      raw = value
    case .stored:
      do {
        // Asked for by host: a key saved for another server is not handed out, so it
        // cannot be sent to this one.
        raw = try await secrets.apiKey(for: server.host)
      } catch let error as WisperError {
        throw error
      } catch {
        throw WisperError.storage("the API key could not be read")
      }
    }
    // A pasted key often carries a stray space or line break.
    let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !key.isEmpty else {
      if server.isOpenAI { throw WisperError.missingAPIKey }
      return Server(root: server.root, key: nil)
    }
    // Anything else cannot travel in a header, so no server would take it.
    guard key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else {
      throw WisperError.invalidAPIKey
    }
    return Server(root: server.root, key: key)
  }

  // MARK: Sending, with retries

  /// How many times one request is sent before giving up.
  static let attempts = 3
  /// A wait the server asks for that is longer than this is not worth it: someone is waiting for their text.
  static let longestWait: TimeInterval = 10

  private func deliver(_ call: Call, to server: Server) async throws -> Data {
    defer {
      if case .file(let url, _) = call.body { try? FileManager.default.removeItem(at: url) }
    }
    let request = try request(for: call, on: server)
    var attempt = 1
    while true {
      try Task.checkCancellation()
      let failure: Failure
      do {
        let (data, response) = try await perform(request, body: call.body)
        guard let http = response as? HTTPURLResponse else {
          throw WisperError.invalidResponse("the server did not answer over HTTP")
        }
        if (200..<300).contains(http.statusCode) { return data }
        failure = Failure(status: http.statusCode, response: http, body: data)
      } catch let error as URLError {
        if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
        failure = Failure(error)
      }
      guard failure.transient, attempt < Client.attempts else { throw failure.error }
      // Wait 0.5 s, then 1 s, unless the server says how long.
      let wait = failure.retryAfter ?? 0.5 * pow(2, Double(attempt - 1))
      guard wait <= Client.longestWait else { throw failure.error }
      try await pause(wait)
      attempt += 1
    }
  }

  private func perform(_ request: URLRequest, body: Call.Body) async throws -> (Data, URLResponse) {
    let guide = SameHostRedirects()
    do {
      switch body {
      case .none: return try await session.data(for: request, delegate: guide)
      case .json(let data): return try await session.upload(for: request, from: data, delegate: guide)
      case .file(let url, _): return try await session.upload(for: request, fromFile: url, delegate: guide)
      }
    } catch let error as URLError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw URLError(.unknown)
    }
  }

  private func request(for call: Call, on server: Server) throws -> URLRequest {
    guard var parts = URLComponents(url: server.root, resolvingAgainstBaseURL: true) else {
      throw WisperError.network("the server address is not valid")
    }
    parts.path += "/" + call.path
    guard let url = parts.url else { throw WisperError.network("the server address is not valid") }
    var request = URLRequest(url: url)
    request.httpMethod = call.method
    request.timeoutInterval = call.idle
    // Never answer from a cache (a cached "OK" would make a bad key look good), and keep no cookies.
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let key = server.key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    switch call.body {
    case .none: break
    case .json: request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    case .file(_, let contentType): request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    return request
  }
}

// MARK: - Redirects

/// Lets a request follow a redirect only while it stays with the server it was sent to.
///
/// A redirect to another host (or from `https` down to `http`) would hand the recording, the
/// prompt and perhaps the key to a server nobody chose. Such a redirect is not followed: the
/// redirect answer itself comes back, and is reported as an error.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    guard let from = task.originalRequest?.url, let to = request.url,
      SameHostRedirects.staysWithTheServer(from: from, to: to)
    else { return nil }
    return request
  }

  static func staysWithTheServer(from: URL, to: URL) -> Bool {
    guard let host = from.host, let next = to.host, APIServer.sameHost(host, next) else { return false }
    let downgraded = from.scheme?.lowercased() == "https" && to.scheme?.lowercased() != "https"
    return !downgraded
  }
}

// MARK: - Failures

/// One failed attempt: what to tell the person, and whether trying again could help.
private struct Failure {
  var error: any Error
  var transient = false
  var retryAfter: TimeInterval?

  /// The request never got an answer.
  init(_ error: URLError) {
    let reason: String
    switch error.code {
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: reason = "you are offline"
    case .timedOut: reason = "the request timed out"
    case .cannotFindHost, .dnsLookupFailed: reason = "the server was not found"
    case .cannotConnectToHost: reason = "the server did not answer"
    case .networkConnectionLost: reason = "the connection was lost"
    case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
      .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
      .appTransportSecurityRequiresSecureConnection:
      reason = "a secure connection could not be made"
    case .badURL, .unsupportedURL: reason = "the server address is not valid"
    default: reason = "the connection failed"
    }
    self.error = WisperError.network(reason)
    switch error.code {
    case .notConnectedToInternet, .timedOut, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
      .networkConnectionLost, .resourceUnavailable, .badServerResponse:
      transient = true
    default:
      transient = false
    }
  }

  /// The server answered with an error status.
  init(status: Int, response: HTTPURLResponse, body: Data) {
    let refusal = Refusal(status: status, body: body)
    switch status {
    case 401:
      error = WisperError.invalidAPIKey
    case 429 where refusal.isOutOfCredit:
      // Waiting does not bring credit back, so pass on what the server said instead of "try again in a moment".
      error = refusal
    case 429:
      error = WisperError.rateLimited
      transient = true
    case 408, 500...:
      error = refusal
      transient = true
    case 300..<400:
      // A redirect that was not followed, because it led away from the server.
      let target = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0)?.host }
      error = WisperError.server(
        status: status,
        message: "The server tried to pass the request on to another address"
          + (target.map { " (\($0))" } ?? "") + ". Nothing was sent there."
      )
    default:
      error = refusal
    }
    if let text = response.value(forHTTPHeaderField: "retry-after-ms"), let ms = Double(text), ms >= 0 {
      retryAfter = ms / 1000
    } else if let text = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(text),
      seconds >= 0
    {
      retryAfter = seconds
    }
  }
}

/// An error answer from the server. OpenAI's look like `{"error": {"message", "type", "param", "code"}}`.
struct Refusal: Error {
  var status: Int
  /// What the server said, on one line. May repeat the key back: show `asWisperError` instead.
  private var message: String
  private var parameter: String?
  private var code: String?
  private var type: String?
  /// The whole answer in lower case, for servers that explain themselves in some other shape.
  private var raw: String

  init(status: Int, body: Data) {
    self.status = status
    raw = String(decoding: body.prefix(4_000), as: UTF8.self).lowercased()
    let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    var message: String?
    if let detail = json?["error"] as? [String: Any] {
      message = detail["message"] as? String
      parameter = detail["param"] as? String
      code = detail["code"] as? String
      type = detail["type"] as? String
    } else {
      // Other servers keep it simpler: {"error": "..."}, {"message": "..."} or {"detail": "..."}.
      message = ["error", "message", "detail"].lazy.compactMap { json?[$0] as? String }.first
    }
    // Kept whole here. It is cut to length only after the key has been hidden, so a key that
    // sits across the cut cannot leave its first half behind.
    self.message = (message ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  /// The longest message passed on to a person.
  static let longestMessage = 300

  /// Out of credit or over a spending limit. Trying again will not help.
  var isOutOfCredit: Bool {
    let billing: Set<String> = [
      "insufficient_quota", "credit_balance_exhausted", "billing_hard_limit_reached",
      "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
      "organization_usage_limit_exceeded",
    ]
    return [code, type].compactMap { $0 }.contains(where: billing.contains)
  }

  /// The one optional setting this answer says the server will not take, if any.
  func refusedSetting(among names: Set<String>) -> String? {
    guard status == 400 || status == 422, !names.isEmpty else { return nil }
    if let parameter {
      // "keywords[0]" and "response_format.schema" name the setting at their start.
      let root = parameter.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
      if let hit = names.first(where: { $0 == root }) { return hit }
    }
    // Some servers only say it in words: "Unrecognized request argument supplied: temperature".
    let complaints = [
      "unsupported", "not supported", "unrecognized", "unknown", "unexpected", "not permitted", "not allowed",
      "extra inputs", "extra_forbidden",
    ]
    guard complaints.contains(where: raw.contains) else { return nil }
    let mentioned = names.filter { name in
      raw.range(of: #"(?<![a-z_])\#(name)(?![a-z_])"#, options: .regularExpression) != nil
    }
    return mentioned.count == 1 ? mentioned.first : nil
  }

  /// What the person sees. The key is cut out in case a server repeats it back.
  func asWisperError(hiding key: String?) -> WisperError {
    var text = message
    if let key, !key.isEmpty { text = text.replacingOccurrences(of: key, with: "(key hidden)") }
    text = String(text.prefix(Refusal.longestMessage))
    return .server(status: status, message: text.isEmpty ? "The server gave no details." : text)
  }
}

/// Remembers which optional settings were refused, so later requests skip the wasted round trip.
/// Kept only in memory: after a restart the settings are tried again.
private actor Memory {
  private var refused: [String: Set<String>] = [:]

  func refused(in scope: String) -> Set<String> { refused[scope] ?? [] }

  func remember(_ names: Set<String>, in scope: String) {
    if !names.isEmpty { refused[scope, default: []].formUnion(names) }
  }
}

/// Runs `work`, and gives up with a "timed out" error when it takes longer than `seconds`.
private func withDeadline<T: Sendable>(
  _ seconds: TimeInterval,
  _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await work() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw WisperError.network("the request timed out")
    }
    defer { group.cancelAll() }
    guard let first = try await group.next() else { throw CancellationError() }
    return first
  }
}
