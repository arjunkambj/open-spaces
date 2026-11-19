import Foundation
import WisperDomain

/// Knows what kind of app the user is dictating into, so the right writing
/// style can be picked. To teach it a new app, add a line to one of the tables.
enum AppCatalog {
  /// Apps by bundle ID. A trailing `*` matches any ending.
  static let apps: [String: AppCategory] = [
    // Personal messages
    "com.apple.MobileSMS": .personalMessages,
    "com.apple.iChat": .personalMessages,
    "net.whatsapp.WhatsApp": .personalMessages,
    "desktop.WhatsApp": .personalMessages,
    "ru.keepcoder.Telegram": .personalMessages,
    "org.telegram.desktop": .personalMessages,
    "com.tdesktop.Telegram": .personalMessages,
    "org.whispersystems.signal-desktop": .personalMessages,
    "com.facebook.archon*": .personalMessages,
    "jp.naver.line.mac": .personalMessages,
    "com.tencent.xinWeChat": .personalMessages,
    "com.viber.osx": .personalMessages,
    "com.kakao.KakaoTalkMac": .personalMessages,
    // Work messages
    "com.tinyspeck.slackmacgap": .workMessages,
    "com.microsoft.teams*": .workMessages,
    "com.hnc.Discord*": .workMessages,
    "com.mattermost.desktop": .workMessages,
    "Mattermost.Desktop": .workMessages,
    "com.cisco.webexmeetingsapp": .workMessages,
    "Cisco-Systems.Spark": .workMessages,
    "com.google.GoogleChat": .workMessages,
    "com.electron.lark": .workMessages,
    "com.bytedance.macos.feishu": .workMessages,
    // Email
    "com.apple.mail": .email,
    "com.microsoft.Outlook": .email,
    "com.superhuman.electron": .email,
    "com.superhuman.mail": .email,
    "com.readdle.smartemail-Mac": .email,
    "com.readdle.SparkDesktop*": .email,
    "com.mimestream.Mimestream": .email,
    "com.freron.MailMate": .email,
    "it.bloop.airmail2": .email,
    "io.canarymail.mac": .email,
    "ch.protonmail.desktop": .email,
    "com.hey.app.desktop": .email,
    "org.mozilla.thunderbird": .email,
    "com.fastmail.mac.Fastmail": .email,
    "notion.mail.id": .email,
  ]

  /// Browsers. Inside one of these the page decides the category.
  static let browsers: [String] = [
    "com.apple.Safari*", "com.google.Chrome*", "org.chromium.Chromium", "company.thebrowser.Browser",
    "company.thebrowser.dia", "com.microsoft.edgemac*", "com.brave.Browser*", "org.mozilla.firefox*",
    "org.mozilla.nightly", "com.operasoftware.Opera*", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS",
    "app.zen-browser.zen", "net.imput.helium", "com.duckduckgo.macos.browser", "ai.perplexity.comet",
    "com.openai.atlas",
  ]

  /// A website that counts as an app. `hosts` match the address of the page
  /// (and its subdomains); `titles` match one part of the window title, the
  /// way sites put their name at the start or end ("Inbox - Gmail").
  struct Site: Sendable {
    var category: AppCategory
    var hosts: [String]
    var titles: [String]
  }

  static let sites: [Site] = [
    Site(category: .email, hosts: ["mail.google.com"], titles: ["Gmail"]),
    Site(
      category: .email,
      hosts: ["outlook.live.com", "outlook.office.com", "outlook.office365.com", "outlook.cloud.microsoft"],
      titles: ["Outlook"]
    ),
    Site(category: .email, hosts: ["mail.proton.me"], titles: ["Proton Mail"]),
    Site(category: .email, hosts: ["mail.yahoo.com"], titles: ["Yahoo Mail"]),
    Site(category: .email, hosts: ["app.fastmail.com"], titles: ["Fastmail"]),
    Site(category: .email, hosts: ["icloud.com/mail"], titles: ["iCloud Mail"]),
    Site(category: .email, hosts: ["mail.superhuman.com"], titles: ["Superhuman"]),
    Site(category: .email, hosts: ["app.hey.com"], titles: ["HEY"]),
    Site(category: .email, hosts: ["mail.zoho.com"], titles: ["Zoho Mail"]),
    Site(category: .workMessages, hosts: ["app.slack.com"], titles: ["Slack"]),
    Site(
      category: .workMessages,
      hosts: ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"],
      titles: ["Microsoft Teams"]
    ),
    Site(category: .workMessages, hosts: ["discord.com"], titles: ["Discord"]),
    Site(
      category: .workMessages,
      hosts: ["chat.google.com", "mail.google.com/chat"],
      titles: ["Google Chat"]
    ),
    Site(category: .personalMessages, hosts: ["web.whatsapp.com"], titles: ["WhatsApp", "WhatsApp Web"]),
    Site(category: .personalMessages, hosts: ["web.telegram.org"], titles: ["Telegram", "Telegram Web"]),
    Site(category: .personalMessages, hosts: ["messenger.com"], titles: ["Messenger"]),
    Site(category: .personalMessages, hosts: ["messages.google.com"], titles: ["Google Messages"]),
    Site(category: .personalMessages, hosts: ["instagram.com/direct"], titles: []),
  ]

  static func isBrowser(_ bundleID: String?) -> Bool {
    guard let bundleID else { return false }
    return browsers.contains { matches(bundleID, pattern: $0) }
  }

  /// The category for an app. For a browser, pass the title of its front
  /// window and the address of the page when they are known.
  static func category(bundleID: String?, windowTitle: String? = nil, url: String? = nil) -> AppCategory {
    guard let bundleID else { return .other }
    if isBrowser(bundleID) {
      return site(url: url)?.category ?? site(title: windowTitle)?.category ?? .other
    }
    if let exact = apps.first(where: { $0.key.caseInsensitiveCompare(bundleID) == .orderedSame }) {
      return exact.value
    }
    return apps.first { $0.key.hasSuffix("*") && matches(bundleID, pattern: $0.key) }?.value ?? .other
  }

  private static func matches(_ bundleID: String, pattern: String) -> Bool {
    let id = bundleID.lowercased()
    let pattern = pattern.lowercased()
    if pattern.hasSuffix("*") { return id.hasPrefix(pattern.dropLast()) }
    return id == pattern
  }

  private static func site(url: String?) -> Site? {
    guard let url, let parts = URLComponents(string: url), let host = parts.host?.lowercased() else {
      return nil
    }
    let path = parts.path.lowercased()
    func matches(_ pattern: String, needsPath: Bool) -> Bool {
      let pieces = pattern.split(separator: "/", maxSplits: 1)
      guard let wantedHost = pieces.first.map(String.init), (pieces.count == 2) == needsPath else {
        return false
      }
      guard host == wantedHost || host.hasSuffix("." + wantedHost) else { return false }
      return !needsPath || path.hasPrefix("/" + pieces[1])
    }
    // An address with a path is the more exact one: mail.google.com/chat is
    // Google Chat even though mail.google.com is Gmail.
    return sites.first { $0.hosts.contains { matches($0, needsPath: true) } }
      ?? sites.first { $0.hosts.contains { matches($0, needsPath: false) } }
  }

  private static func site(title: String?) -> Site? {
    guard let title else { return nil }
    let parts = titleParts(title)
    return sites.first { site in
      site.titles.contains { name in parts.contains(name.lowercased()) }
    }
  }

  /// Splits "Inbox (3) - me@example.com - Gmail" into its parts, lower-cased,
  /// without unread counts such as "(3)".
  static func titleParts(_ title: String) -> [String] {
    var text = title
    for separator in [" – ", " — ", " | ", " · ", " • "] {
      text = text.replacingOccurrences(of: separator, with: " - ")
    }
    return text.components(separatedBy: " - ").map { part in
      part.replacingOccurrences(of: #"^\s*\([^)]*\)\s*"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
        .lowercased()
    }.filter { !$0.isEmpty }
  }
}
