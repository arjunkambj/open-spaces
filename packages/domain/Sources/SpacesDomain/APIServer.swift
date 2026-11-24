import Foundation

/// The server that speech and text requests go to: OpenAI itself, or the
/// OpenAI-compatible server named by `Settings.apiBaseURL`.
///
/// This is the one place that decides what an address means, so the screens,
/// the app model and the network code cannot disagree about where audio and
/// the API key are sent.
///
/// **The rule.** No address (or only white space) means OpenAI. Any other
/// address must be `http://` or `https://` with a host name; it is taken as
/// the folder that holds the API, and the endpoint is added to it:
/// `https://example.com/api/v1` becomes `https://example.com/api/v1/chat/completions`.
/// A trailing slash makes no difference, and anything after a `?` is kept. An
/// address with no path at all (`http://localhost:11434`) gets `/v1` added,
/// because that is where every compatible server keeps its API.
///
/// An address that is set but does not fit the rule is an error
/// (`SpacesError.invalidServerAddress`). It never quietly means OpenAI: the
/// person chose another server, so nothing may go to OpenAI behind their back.
public struct APIServer: Sendable, Hashable {
  /// The folder that holds the API, without a trailing slash.
  public let root: URL
  /// The server's host name in lower case, e.g. `api.openai.com`. A saved API
  /// key belongs to one host and is never sent to another.
  public let host: String

  /// The host of OpenAI's own API.
  public static let openAIHost = "api.openai.com"

  /// OpenAI's own API, `https://api.openai.com/v1`.
  public static let openAI = APIServer(root: URL(string: "https://api.openai.com/v1")!, host: openAIHost)

  /// The host of Anthropic's API, where requests for Claude models go.
  public static let anthropicHost = "api.anthropic.com"

  /// Anthropic's API, `https://api.anthropic.com/v1`. Claude models are always asked here: the
  /// custom server address is for OpenAI-compatible servers only.
  public static let anthropic = APIServer(
    root: URL(string: "https://api.anthropic.com/v1")!,
    host: anthropicHost
  )

  /// Whether this is OpenAI itself rather than a server the person set.
  public var isOpenAI: Bool { host == APIServer.openAIHost }

  /// The server a `Settings.apiBaseURL` value means.
  ///
  /// - Throws: `SpacesError.invalidServerAddress` when `address` holds text
  ///   that is not a usable `http://` or `https://` address.
  public init(address: String?) throws {
    let text = (address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      self = .openAI
      return
    }
    guard !text.contains(where: \.isWhitespace), var parts = URLComponents(string: text),
      let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = parts.host?.lowercased(), !host.isEmpty
    else { throw SpacesError.invalidServerAddress }
    parts.scheme = scheme
    parts.host = host
    parts.fragment = nil
    var path = parts.path
    while path.hasSuffix("/") { path.removeLast() }
    parts.path = path.isEmpty ? "/v1" : path
    guard let root = parts.url else { throw SpacesError.invalidServerAddress }
    self.init(root: root, host: host)
  }

  private init(root: URL, host: String) {
    self.root = root
    self.host = host
  }

  /// Whether two host names mean the same server. Case and white space around them do not count.
  public static func sameHost(_ one: String, _ other: String) -> Bool {
    func tidy(_ host: String) -> String { host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    return tidy(one) == tidy(other)
  }
}

extension Settings {
  /// The server these settings name. See `APIServer` for the rule.
  ///
  /// - Throws: `SpacesError.invalidServerAddress` when `apiBaseURL` is set but unusable.
  public func apiServer() throws -> APIServer {
    try APIServer(address: apiBaseURL)
  }
}

extension SpacesError {
  /// The message to show for this error when requests go to `server`.
  ///
  /// For OpenAI itself this is `errorDescription`. For a server the person
  /// set, the messages name that server's host instead of OpenAI, and do not
  /// blame the internet connection for a server that may be on this device.
  public func message(server: APIServer) -> String {
    let host = server.host
    guard !server.isOpenAI else { return errorDescription ?? "Something went wrong." }
    switch self {
    case .missingAPIKey:
      // A key saved for another server is never sent to this one, so it has to be entered again.
      return "\(host) asked for an API key. Add the key for this server in Settings."
    case .invalidAPIKey:
      return "\(host) did not accept your API key. Check it in Settings."
    case .rateLimited:
      return "\(host) is limiting requests right now. Try again in a moment."
    case .network(SpacesError.noAnswerDetail):
      return "\(host) did not answer in time, even on a second try. Check that the server is running"
        + " and the address in Settings is right."
    case .network(let detail):
      return "Could not reach \(host). Check that the server is running and the address in Settings is right."
        + " (\(detail))"
    case .server(let status, let message):
      return "\(host) returned an error (\(status)): \(message)"
    case .invalidResponse(let detail):
      return "\(host) sent a reply that could not be read: \(detail)"
    case .invalidServerAddress, .replyTooLong, .noSpeech, .permissionDenied, .captureFailed,
      .notFound, .storage, .invalidInput, .anthropic:
      return errorDescription ?? "Something went wrong."
    }
  }
}
