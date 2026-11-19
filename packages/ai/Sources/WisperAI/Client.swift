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
  private let connections = Connections()
  private let memory = Memory()

  /// - Parameter address: the text of the custom server address, or `nil` for OpenAI itself.
  init(secrets: any SecretStore, address: @escaping @Sendable () async throws -> String?) {
    self.secrets = secrets
    self.address = address
  }

  // MARK: Interface

  /// One request, described without the server address or the key.
  struct Call: Sendable {
    var method: String
    /// Endpoint under the API folder, e.g. `chat/completions`.
    var path: String
    var body: Body = .none
    /// How long the server may take to answer once the request has been sent, in seconds, on
    /// the first try. A try that follows one without an answer waits twice as long: a
    /// connection that has gone dead is given up quickly, and a server that is only slow
    /// today still gets its time.
    var wait: TimeInterval
    /// The longest the sending itself may stand still, in seconds: no connection yet, or no
    /// more of the body going out.
    var stall: TimeInterval = Client.longestStall

    enum Body: Sendable {
      case none
      case json(Data)
      /// A body already written to a file. The client deletes the file once it has been sent.
      case file(URL, contentType: String)

      /// Whether there is anything to send besides the request line.
      var isSent: Bool {
        if case .none = self { return false }
        return true
      }
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
          let data = try await deliver(try await build(leftOut), to: server, within: budget)
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

  /// Gets a working connection to the server ready, so the request that follows starts at once.
  ///
  /// Sends one small question that carries no key, no audio and no text, and only when a real
  /// request could go out: with an address that cannot be used, or with no key for OpenAI,
  /// nothing is sent. Never throws: when it does not work out, the request itself will say why.
  func prepare() async {
    guard let server = try? await resolve(.stored),
      var parts = URLComponents(url: server.root, resolvingAgainstBaseURL: true)
    else { return }
    parts.path += "/models"
    guard let url = parts.url else { return }
    await connections.warm { session, probe in
      await Client.reaches(url, on: session, within: probe == .check ? Client.checkTime : Client.openTime)
    }
  }

  /// A WebSocket to `path` under the API folder of the server the settings name, not yet
  /// started. It carries that server's key, and only that server's. It follows no redirect
  /// to another host.
  ///
  /// - Throws: `WisperError`, before anything is sent, when a request could not be sent
  ///   either: the address cannot be used, or there is no key for OpenAI.
  func socket(path: String, query: [URLQueryItem]) async throws -> URLSessionWebSocketTask {
    let server = try await resolve(.stored)
    guard var parts = URLComponents(url: server.root, resolvingAgainstBaseURL: true) else {
      throw WisperError.network("the server address is not valid")
    }
    parts.path += "/" + path
    parts.scheme = parts.scheme?.lowercased() == "http" ? "ws" : "wss"
    parts.queryItems = (parts.queryItems ?? []) + query
    guard let url = parts.url else { throw WisperError.network("the server address is not valid") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.httpShouldHandleCookies = false
    if let key = server.key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    let task = connections.current().webSocketTask(with: request)
    task.delegate = SameHostRedirects()
    return task
  }

  /// How long a connection that was in use gets to show it is still alive. One that works
  /// answers in well under a second.
  static let checkTime: TimeInterval = 2.5
  /// How long opening a first connection may take. Measured on a VPN: two seconds, now and then.
  static let openTime: TimeInterval = 8

  /// Whether the server gave any answer at all to a question about `url`. What it answered
  /// does not matter ("not allowed" comes over a working connection too).
  private static func reaches(_ url: URL, on session: URLSession, within seconds: TimeInterval) async -> Bool
  {
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = seconds
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.httpShouldHandleCookies = false
    return (try? await session.data(for: request, delegate: SameHostRedirects())) != nil
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

  /// The longest the sending of a request may stand still, unless a call says otherwise. Long
  /// enough to open a connection on a poor network.
  static let longestStall: TimeInterval = 8
  /// How many tries may end without an answer. After the second, the person is told: they are waiting.
  static let silentTries = 2

  private func deliver(_ call: Call, to server: Server, within budget: TimeInterval) async throws -> Data {
    defer {
      if case .file(let url, _) = call.body { try? FileManager.default.removeItem(at: url) }
    }
    var request = try request(for: call, on: server)
    // The system's own timer is only a backstop behind the limits kept here.
    request.timeoutInterval = budget
    var attempt = 1
    var silent = 0
    while true {
      try Task.checkCancellation()
      // A check of the connection that began when the key went down gets to finish: when it
      // finds the connection dead, this request goes out on a fresh one from the start.
      await connections.settled()
      let session = connections.current()
      let wait = call.wait * pow(2, Double(silent))
      let failure: Failure
      do {
        let (data, response) = try await perform(
          request,
          body: call.body,
          on: session,
          limits: Watch(wait: wait, stall: call.stall, hasBody: call.body.isSent)
        )
        guard let http = response as? HTTPURLResponse else {
          throw WisperError.invalidResponse("the server did not answer over HTTP")
        }
        // Any answer, good or bad, came over a connection that works.
        connections.used(session)
        if (200..<300).contains(http.statusCode) { return data }
        failure = Failure(status: http.statusCode, response: http, body: data)
      } catch let error as URLError {
        if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
        failure = Failure(error)
        // Whatever went wrong, it went wrong on this session's connections. The next try, and
        // every later request, starts on new ones, so a dead connection is never used twice.
        connections.renew(after: session)
        if error.code == .timedOut {
          silent += 1
          guard silent < Client.silentTries, attempt < Client.attempts else {
            throw WisperError.noAnswer
          }
          // No pause: the waiting has been done already.
          attempt += 1
          continue
        }
      }
      guard failure.transient, attempt < Client.attempts else { throw failure.error }
      // Wait 0.5 s, then 1 s, unless the server says how long.
      let pauseFor = failure.retryAfter ?? 0.5 * pow(2, Double(attempt - 1))
      guard pauseFor <= Client.longestWait else { throw failure.error }
      try await Task.sleep(for: .seconds(pauseFor))
      attempt += 1
    }
  }

  /// Sends the request once. Throws `URLError(.timedOut)` when `limits` says it took too long.
  private func perform(
    _ request: URLRequest,
    body: Call.Body,
    on session: URLSession,
    limits watch: Watch
  ) async throws -> (Data, URLResponse) {
    try await withThrowingTaskGroup(of: (Data, URLResponse)?.self) { group in
      group.addTask {
        do {
          switch body {
          case .none: return try await session.data(for: request, delegate: watch)
          case .json(let data): return try await session.upload(for: request, from: data, delegate: watch)
          case .file(let url, _):
            return try await session.upload(for: request, fromFile: url, delegate: watch)
          }
        } catch let error as URLError {
          throw error
        } catch is CancellationError {
          throw URLError(.cancelled)
        } catch {
          throw URLError(.unknown)
        }
      }
      group.addTask {
        try await watch.expire()
        return nil
      }
      // Leaving stops whichever of the two is still running: the request, or the clock.
      defer { group.cancelAll() }
      do {
        guard let first = try await group.next(), let answer = first else { throw URLError(.timedOut) }
        return answer
      } catch is CancellationError {
        throw URLError(.cancelled)
      }
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
    let secure: Set<String> = ["https", "wss"]
    let downgraded =
      secure.contains(from.scheme?.lowercased() ?? "") && !secure.contains(to.scheme?.lowercased() ?? "")
    return !downgraded
  }
}

// MARK: - Giving up on one try

/// Follows one try of a request, and says when it has taken too long.
///
/// Two different silences are told apart. While the request is still going out, only a
/// standstill counts (`stall`): a long recording on a slow connection is fine as long as it
/// keeps moving. Once all of it has gone out, the server has `wait` seconds to answer.
///
/// It is also the request's guide for redirects, with the same rule as `SameHostRedirects`.
///
/// `@unchecked Sendable`: the mutable properties are read and written while holding `lock`.
private final class Watch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let wait: TimeInterval
  private let stall: TimeInterval
  private let lock = NSLock()
  private var lastProgress = ContinuousClock.now
  private var sent: Bool

  /// - Parameter hasBody: Whether the request has a body to send. One without is waiting for
  ///   its answer from the start.
  init(wait: TimeInterval, stall: TimeInterval, hasBody: Bool) {
    self.wait = wait
    self.stall = stall
    sent = !hasBody
  }

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

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    lock.withLock {
      lastProgress = .now
      if totalBytesExpectedToSend > 0, totalBytesSent >= totalBytesExpectedToSend { sent = true }
    }
  }

  /// Returns when the try has run out of time. Throws only when its task is cancelled.
  func expire() async throws {
    while true {
      let (deadline, fixed) = lock.withLock {
        // While sending is not known to be over, the longer of the two limits holds: should
        // its end go unreported, the server still gets its full time to answer.
        (lastProgress + .seconds(sent ? wait : max(stall, wait)), sent)
      }
      let now = ContinuousClock.now
      if now >= deadline { return }
      // While the request is going out the limit moves with it, so it is looked at again
      // every moment. Once everything is sent, it stays where it is.
      try await Task.sleep(
        until: fixed ? deadline : min(deadline, now + .milliseconds(100)),
        clock: .continuous
      )
    }
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
    case .timedOut: reason = ""
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
    self.error = error.code == .timedOut ? WisperError.noAnswer : WisperError.network(reason)
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

/// Runs `work`, and gives up with a "no answer" error when it takes longer than `seconds`.
private func withDeadline<T: Sendable>(
  _ seconds: TimeInterval,
  _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await work() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw WisperError.noAnswer
    }
    defer { group.cancelAll() }
    guard let first = try await group.next() else { throw CancellationError() }
    return first
  }
}
