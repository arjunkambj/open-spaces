import AppKit
import Observation
import WisperDomain

/// Where the hub window is: the open section, the open meeting, whether
/// Settings is up, and the few choices about the window itself.
///
/// The section, the sidebar and the theme are remembered between launches
/// when the hub is given a `UserDefaults`.
@MainActor
@Observable
public final class HubNavigation {
  /// A page of the hub, in sidebar order.
  public enum Section: String, CaseIterable, Sendable, Identifiable {
    case home, meetings, dictionary, snippets, style

    public var id: String { rawValue }

    public var title: String {
      switch self {
      case .home: "Home"
      case .meetings: "Meetings"
      case .dictionary: "Dictionary"
      case .snippets: "Snippets"
      case .style: "Style"
      }
    }

    /// The SF Symbol shown beside the title.
    public var symbol: String {
      switch self {
      case .home: "house"
      case .meetings: "record.circle"
      case .dictionary: "character.book.closed"
      case .snippets: "text.quote"
      case .style: "textformat"
      }
    }
  }

  /// Light, dark, or whatever the Mac is set to.
  public enum Theme: String, CaseIterable, Sendable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }

    public var title: String {
      switch self {
      case .system: "Match the Mac"
      case .light: "Light"
      case .dark: "Dark"
      }
    }

    public var symbol: String {
      switch self {
      case .system: "circle.lefthalf.filled"
      case .light: "sun.max"
      case .dark: "moon"
      }
    }

    /// The appearance to give the app, or `nil` to follow the system.
    public var appearance: NSAppearance? {
      switch self {
      case .system: nil
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      }
    }
  }

  public var section: Section {
    didSet { defaults?.set(section.rawValue, forKey: Key.section) }
  }
  /// The meeting open in the Meetings section; `nil` shows the list.
  public var meeting: Meeting.ID?
  public var showsSettings = false
  public var sidebarHidden: Bool {
    didSet { defaults?.set(sidebarHidden, forKey: Key.sidebarHidden) }
  }
  public var theme: Theme {
    didSet { defaults?.set(theme.rawValue, forKey: Key.theme) }
  }
  /// Set by the window: in full screen there are no window buttons to leave room for.
  public var isFullScreen = false

  @ObservationIgnored private let defaults: UserDefaults?

  private enum Key {
    static let section = "hub.section"
    static let sidebarHidden = "hub.sidebarHidden"
    static let theme = "hub.theme"
  }

  /// - defaults: where the choices are remembered, or `nil` to remember nothing (demo, snapshots).
  public init(defaults: UserDefaults? = nil) {
    self.defaults = defaults
    section = defaults?.string(forKey: Key.section).flatMap(Section.init(rawValue:)) ?? .home
    sidebarHidden = defaults?.bool(forKey: Key.sidebarHidden) ?? false
    theme = defaults?.string(forKey: Key.theme).flatMap(Theme.init(rawValue:)) ?? .system
  }

  /// Goes to a section and closes Settings.
  public func show(_ section: Section) {
    showsSettings = false
    self.section = section
  }

  /// Opens one meeting in the Meetings section.
  public func show(meeting id: Meeting.ID) {
    show(.meetings)
    meeting = id
  }
}
