import Foundation
import WisperDomain

/// Sends one request to the user's server and brings back the reply body.
///
/// Everything the two adapters share lives here: the address rule, the key,
/// timeouts, retries, turning failures into `WisperError`, and leaving out
/// optional settings a server does not accept.
struct Client: Sendable {
  private let secrets: any SecretStore
  private let baseURL: @Sendable () async -> URL?
  private let session: URLSession
  private let pause: @Sendable (TimeInterval) async throws -> Void
  private let memory = Memory()

  init(
    secrets: any SecretStore,
    baseURL: @escaping @Sendable () async -> URL?,
    session: URLSession,
    pause: @escaping @Sendable (TimeInterval) async throws -> Void
  ) {
    self.secrets = secrets
    self.baseURL = baseURL
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
        }
      }
    }
  }

  /// Whether requests go to OpenAI itself rather than to a server the user set.
  func usesOpenAI() async -> Bool {
    Client.root(for: await baseURL()).host == Client.openAI.host
  }

  // MARK: Where and who

  private struct Server: Sendable {
    /// The folder that holds the API, without a trailing slash.
    var root: URL
    var key: String?
  }

  static let openAI = URL(string: "https://api.openai.com/v1")!

  /// The folder that holds the API for a custom address. See `OpenAI` for the rule.
  static func root(for custom: URL?) -> URL {
    guard let custom, var parts = URLComponents(url: custom, resolvingAgainstBaseURL: true),
      let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = parts.host, !host.isEmpty
    else { return openAI }
    parts.scheme = scheme
    parts.host = host.lowercased()
    parts.fragment = nil
    var path = parts.path
    while path.hasSuffix("/") { path.removeLast() }
    parts.path = path.isEmpty ? "/v1" : path
    return parts.url ?? openAI
  }

  private func resolve(_ key: Key) async throws -> Server {
    let root = Client.root(for: await baseURL())
    let raw: String?
    switch key {
    case .given(let value):
      raw = value
    case .stored:
      do {
        raw = try await secrets.apiKey()
      } catch let error as WisperError {
        throw error
      } catch {
        throw WisperError.storage("the API key could not be read")
      }
    }
    // A pasted key often carries a stray space or line break.
    let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !key.isEmpty else {
      if root.host == Client.openAI.host { throw WisperError.missingAPIKey }
      return Server(root: root, key: nil)
    }
    // Anything else cannot travel in a header, so no server would take it.
    guard key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else {
      throw WisperError.invalidAPIKey
    }
    return Server(root: root, key: key)
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
    do {
      switch body {
      case .none: return try await session.data(for: request)
      case .json(let data): return try await session.upload(for: request, from: data)
      case .file(let url, _): return try await session.upload(for: request, fromFile: url)
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
  var message: String
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
    let line = (message ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    self.message = line.isEmpty ? "The server gave no details." : String(line.prefix(300))
  }

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
    return .server(status: status, message: text)
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
