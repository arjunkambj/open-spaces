import Foundation
import WisperDomain

/// The sections of the settings screen, in the order they are listed.
enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
  case general, shortcuts, meetings
  case openAI = "openai"
  case agents, privacy, permissions, about

  /// The labelled groups the sections are listed under.
  enum Group: String, CaseIterable, Identifiable, Sendable {
    case settings, connections, privacy, app

    var id: String { rawValue }

    var title: String {
      switch self {
      case .settings: "Settings"
      case .connections: "Connections"
      case .privacy: "Privacy"
      case .app: "Open Wisper"
      }
    }
  }

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .shortcuts: "Shortcuts"
    case .meetings: "Meetings"
    case .openAI: "OpenAI"
    case .agents: "Agents"
    case .privacy: "Privacy & data"
    case .permissions: "Permissions"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "slider.horizontal.3"
    case .shortcuts: "keyboard"
    case .meetings: "record.circle"
    case .openAI: "key"
    case .agents: "terminal"
    case .privacy: "lock.shield"
    case .permissions: "hand.raised"
    case .about: "info.circle"
    }
  }

  var group: Group {
    switch self {
    case .general, .shortcuts, .meetings: .settings
    case .openAI, .agents: .connections
    case .privacy, .permissions: .privacy
    case .about: .app
    }
  }

  /// The sections of one group. Shortcuts is left out when the platform has no shortcut editor.
  static func sections(in group: Group, hasShortcuts: Bool) -> [SettingsSection] {
    allCases.filter { $0.group == group && ($0 != .shortcuts || hasShortcuts) }
  }
}

/// What someone typed into the "custom server address" field.
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
    guard
      !trimmed.contains(where: \.isWhitespace),
      let parts = URLComponents(string: trimmed),
      let scheme = parts.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = parts.host,
      !host.isEmpty
    else {
      self = .invalid
      return
    }
    self = .custom(trimmed)
  }

  /// False for text that must not be stored.
  var isValid: Bool { self != .invalid }

  /// The value for `Settings.apiBaseURL`: the address, or `nil` for OpenAI (and for invalid text).
  var address: String? {
    if case .custom(let address) = self { return address }
    return nil
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

/// The text someone copies to connect an AI agent to the bundled `wisper` tool.
enum AgentSetup {
  static let serverName = "open-wisper"

  /// The one-line command for Claude Code.
  static func claudeCommand(toolPath: String) -> String {
    "claude mcp add --scope user \(serverName) -- \(shellQuoted(toolPath)) mcp"
  }

  /// The settings block most MCP clients read. The same as `wisper mcp-config` prints.
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

  /// The command that prints the settings block.
  static func configCommand(toolPath: String) -> String {
    "\(shellQuoted(toolPath)) mcp-config"
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
    guard
      let data = try? JSONSerialization.data(withJSONObject: text, options: options),
      let encoded = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return encoded
  }
}

/// The version shown in About and at the foot of the settings navigation.
enum AppVersion {
  /// The app's version, or "dev" when the code is not running from a built app.
  static func text(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
    guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else { return "dev" }
    return version
  }
}

/// Web pages the settings and onboarding screens link to.
enum SetupLinks {
  static let openAIKeys = URL(string: "https://platform.openai.com/api-keys")!
  static let agentsGuide = URL(string: "https://github.com/arjunkambj/open-wisper/blob/main/docs/agents.md")!
  static let repository = URL(string: "https://github.com/arjunkambj/open-wisper")!
}
