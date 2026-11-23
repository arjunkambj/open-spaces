import Foundation
import SpacesDomain

/// The sections of the settings screen, in the order they are listed.
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
  case general, shortcuts, meetings
  case openAI = "openai"
  case agents, privacy, permissions, about

  /// The two groups the sections are listed in, with a gap between them and no labels:
  /// what you set up, then what the app keeps and is.
  enum Group: String, CaseIterable, Identifiable, Sendable {
    case setup, app

    var id: String { rawValue }
  }

  public var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .shortcuts: "Shortcuts"
    case .meetings: "Meetings"
    case .openAI: "AI keys"
    case .agents: "Agents"
    case .privacy: "Privacy"
    case .permissions: "Permissions"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "slider.horizontal.3"
    case .shortcuts: "keyboard"
    case .meetings: "person.2"
    case .openAI: "key"
    case .agents: "terminal"
    case .privacy: "lock.shield"
    case .permissions: "hand.raised"
    case .about: "info.circle"
    }
  }

  var group: Group {
    switch self {
    case .general, .shortcuts, .meetings, .openAI, .agents: .setup
    case .privacy, .permissions, .about: .app
    }
  }

  /// The sections of one group. Shortcuts is left out when the platform has no shortcut editor.
  static func sections(in group: Group, hasShortcuts: Bool) -> [SettingsSection] {
    allCases.filter { $0.group == group && ($0 != .shortcuts || hasShortcuts) }
  }
}

/// What someone typed into the "custom server address" field.
///
/// What counts as a usable address is decided by `APIServer`, the one rule the app model and
/// the network code follow too, so this field can never accept what they would refuse.
enum ServerAddress: Equatable, Sendable {
  /// Nothing typed: use OpenAI itself.
  case openAI
  /// A usable http(s) address, tidied.
  case custom(String)
  /// Text that is not an http(s) address.
  case invalid

  static let invalidMessage = "Enter a web address that starts with http:// or https://."

  init(_ text: String) {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard !trimmed.isEmpty else {
      self = .openAI
      return
    }
    self = (try? APIServer(address: trimmed)) == nil ? .invalid : .custom(trimmed)
  }

  /// False for text that must not be stored.
  var isValid: Bool { self != .invalid }

  /// The value for `Settings.apiBaseURL`: the address, or `nil` for OpenAI (and for invalid text).
  var address: String? {
    if case .custom(let address) = self { return address }
    return nil
  }

  /// The server the text names: OpenAI when nothing is typed, `nil` for invalid text.
  var server: APIServer? {
    switch self {
    case .openAI: .openAI
    case .custom(let address): try? APIServer(address: address)
    case .invalid: nil
    }
  }

  /// The host of a custom server, e.g. `proxy.example.com`. `nil` for OpenAI and for invalid text.
  var customHost: String? {
    guard let server, !server.isOpenAI else { return nil }
    return server.host
  }

  /// Said wherever a custom address is typed, so nobody sends a key somewhere without knowing.
  static let keyNote = "Your key will be sent to this server instead of OpenAI."
  static let notPrivateTitle = "This connection is not private"
  static let notPrivateMessage =
    "Others on the network can read your key and your voice. Use an address that starts with "
    + "https:// if the server has one."

  /// The hosts that are this device itself. Nothing sent to them leaves it.
  private static let thisDevice: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

  /// True when what is sent to the address can be read on the way: it is plain `http://` and
  /// goes to another machine. A server on this device (`localhost`, `127.0.0.1`) is fine.
  var isNotPrivate: Bool {
    guard let server, server.root.scheme == "http" else { return false }
    return !Self.thisDevice.contains(server.host)
  }
}

/// Whether the screens should ask for a key.
enum KeyNeed {
  /// True when requests go to OpenAI itself and no key is saved for it: nothing can work.
  ///
  /// A server the person set may not need a key at all, so the lack of one is no warning
  /// there; when that server does ask for a key, the failed dictation or meeting says so by
  /// name. An address that cannot be used is not a missing key either.
  static func isMissing(hasKey: Bool, settings: Settings) -> Bool {
    guard !hasKey, let server = try? settings.apiServer() else { return false }
    return server.isOpenAI
  }

  /// Whether a saved key is one for the server being typed, when `hasKey` is about the server
  /// the stored settings name. A key belongs to one host and is never sent to another.
  static func savedKeyApplies(hasKey: Bool, stored: Settings, typed: ServerAddress) -> Bool {
    guard hasKey, let typed = typed.server, let stored = try? stored.apiServer() else { return false }
    return APIServer.sameHost(typed.host, stored.host)
  }
}

/// One entry of a model picker: a suggested model, or "Custom…" to type any name.
enum ModelChoice: Hashable, Sendable {
  case named(String)
  case custom

  var title: String {
    switch self {
    case .named(let model): model
    case .custom: "Custom…"
    }
  }

  static func options(suggested: [String]) -> [ModelChoice] {
    suggested.map(ModelChoice.named) + [.custom]
  }

  /// The entry to show as chosen. A model that is not suggested can only have been typed.
  static func selection(current: String, suggested: [String], typing: Bool) -> ModelChoice {
    typing || !suggested.contains(current) ? .custom : .named(current)
  }

  /// The model name to store for typed text, or `nil` while the field is empty.
  static func typedName(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// The spoken languages offered, by code. `nil` stands for "Detect automatically".
enum LanguageOptions {
  static let automaticTitle = "Detect automatically"

  /// "Detect automatically" first, then every language by name.
  static var codes: [String?] {
    [nil] + SpokenLanguage.all.sorted { $0.name < $1.name }.map(\.code)
  }

  static func title(_ code: String?) -> String {
    guard let code else { return automaticTitle }
    return SpokenLanguage.all.first { $0.code == code }?.name ?? code
  }
}

/// The microphones offered, by device ID. `nil` stands for the system default.
enum MicrophoneOptions {
  static let defaultTitle = "System default"

  /// The default first, then every device, then the chosen one if it is not plugged in.
  static func ids(devices: [AudioDevice], selected: String?) -> [String?] {
    var ids: [String?] = [nil] + devices.map(\.id)
    if let selected, !devices.contains(where: { $0.id == selected }) { ids.append(selected) }
    return ids
  }

  static func title(_ id: String?, devices: [AudioDevice]) -> String {
    guard let id else { return defaultTitle }
    return devices.first { $0.id == id }?.name ?? "Not connected"
  }

  /// One line under the setting that says which microphone is really in use.
  static func summary(devices: [AudioDevice], selected: String?) -> String {
    if let selected {
      return devices.contains { $0.id == selected }
        ? "Used for dictation and meetings."
        : "This microphone is not connected. The system default is used instead."
    }
    if let name = devices.first(where: \.isDefault)?.name { return "Using \(name)." }
    return "Follows the microphone chosen in your system settings."
  }
}

/// The text someone copies to connect an AI agent to the bundled `spaces` tool.
enum AgentSetup {
  static let serverName = "open-spaces"

  /// The one-line command for Claude Code.
  static func claudeCommand(toolPath: String) -> String {
    "claude mcp add --scope user \(serverName) -- \(shellQuoted(toolPath)) mcp"
  }

  /// The settings block most MCP clients read. The same as `spaces mcp-config` prints.
  static func jsonConfig(toolPath: String) -> String {
    """
    {
      "mcpServers": {
        "\(serverName)": {
          "command": \(jsonString(toolPath)),
          "args": ["mcp"]
        }
      }
    }
    """
  }

  /// `path` in double quotes, safe to paste into a shell.
  static func shellQuoted(_ path: String) -> String {
    var quoted = ""
    for character in path {
      if "\\\"$`".contains(character) { quoted.append("\\") }
      quoted.append(character)
    }
    return "\"\(quoted)\""
  }

  private static func jsonString(_ text: String) -> String {
    let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
    // A string always has a JSON form.
    let data = try! JSONSerialization.data(withJSONObject: text, options: options)
    return String(decoding: data, as: UTF8.self)
  }
}

/// One AI tool that uses Spaces through `spaces mcp`, as Home and Settings › Agents show it.
/// All the sessions of one tool (Claude Code opens one for each chat) count as one.
struct AgentStatus: Identifiable, Equatable {
  /// The tool's name for people, such as "Claude Code".
  var name: String
  var isConnected: Bool
  /// How many of its `spaces mcp` servers are running.
  var running: Int
  var lastActiveAt: Date
  var version: String?
  var lastTool: String?

  var id: String { name }

  /// One entry per tool, the one used most recently first.
  static func list(_ sessions: [AgentSession]) -> [AgentStatus] {
    var tools: [AgentStatus] = []
    for session in sessions.sorted(by: { $0.lastActiveAt > $1.lastActiveAt }) {
      let name = name(of: session.client)
      if let index = tools.firstIndex(where: { $0.name == name }) {
        if session.isConnected {
          tools[index].isConnected = true
          tools[index].running += 1
        }
      } else {
        tools.append(
          AgentStatus(
            name: name,
            isConnected: session.isConnected,
            running: session.isConnected ? 1 : 0,
            lastActiveAt: session.lastActiveAt,
            version: session.client.version,
            lastTool: session.lastTool
          )
        )
      }
    }
    return tools
  }

  /// The client's own title, or a known name for people, or the name it gave.
  static func name(of client: AgentClient) -> String {
    if let title = client.title { return title }
    switch client.name.lowercased() {
    case "": return "An AI tool"
    case "claude-code": return "Claude Code"
    case "claude-ai": return "Claude Desktop"
    case "codex-mcp-client": return "Codex"
    case "cursor-vscode": return "Cursor"
    default: return client.name
    }
  }

  /// The quiet line on Home, or `nil` when no tool has used Spaces in the last day.
  static func homeLine(_ tools: [AgentStatus], now: Date) -> String? {
    let connected = tools.filter(\.isConnected).map(\.name)
    switch connected.count {
    case 0:
      guard let last = tools.first else { return nil }
      return "\(last.name) · last used \(ago(last.lastActiveAt, now: now))"
    case 1: return "\(connected[0]) is connected"
    case 2: return "\(connected[0]) and \(connected[1]) are connected"
    default: return "\(connected[0]) and \(connected.count - 1) other tools are connected"
    }
  }

  /// The state under the name in Settings › Agents.
  func detail(now: Date) -> String {
    var parts = [isConnected ? "Connected" : "Not connected"]
    if running > 1 { parts.append("\(running) connections") }
    parts.append("last used \(Self.ago(lastActiveAt, now: now))")
    return parts.joined(separator: " · ")
  }

  /// "just now", "4 minutes ago", "2 hours ago", "3 days ago".
  static func ago(_ date: Date, now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
    func count(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s") ago" }
    if minutes < 1 { return "just now" }
    if minutes < 60 { return count(minutes, "minute") }
    if minutes < 24 * 60 { return count(minutes / 60, "hour") }
    return count(minutes / (24 * 60), "day")
  }
}

/// The version shown in About and at the foot of the settings navigation.
enum AppVersion {
  /// The app's version, or "dev" when the code is not running from a built app (the snapshot tools).
  static var text: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }
}

/// Web pages the settings and onboarding screens link to.
enum SetupLinks {
  static let openAIKeys = URL(string: "https://platform.openai.com/api-keys")!
  static let anthropicKeys = URL(string: "https://platform.claude.com/settings/keys")!
  static let agentsGuide = URL(string: "https://github.com/arjunkambj/open-spaces/blob/main/docs/agents.md")!
  static let repository = URL(string: "https://github.com/arjunkambj/open-spaces")!
}
