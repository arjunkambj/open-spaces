import SwiftUI
import WisperDomain
import WisperEngine
import WisperMac
import WisperUI

/// The content of the main window: first-run setup until it is done, then the
/// sidebar and the selected screen, with Settings as a card on top.
///
/// Reads `AppModel` and `MacControls` from the environment. Give it a window
/// whose content runs under a transparent title bar.
public struct HubView: View {
  @Environment(AppModel.self) private var model
  @Environment(MacControls.self) private var controls
  @Bindable private var navigation: HubNavigation

  public init(navigation: HubNavigation) {
    self.navigation = navigation
  }

  public var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Wisper.Color.window.ignoresSafeArea())
      .environment(\.wisperIdiom, .mac)
  }

  @ViewBuilder private var content: some View {
    if !model.isLoaded {
      SwiftUI.Color.clear
    } else if !model.settings.isOnboarded {
      OnboardingFlow(practice: AnyView(PracticeStep()))
    } else {
      hub
    }
  }

  private var hub: some View {
    GeometryReader { proxy in
      // The window's title bar is see-through and sits over the top of this view.
      let strip = max(proxy.safeAreaInsets.top, HubMetrics.minimumStrip)
      VStack(spacing: 0) {
        TitleStrip(navigation: navigation)
          .frame(height: strip)
        HStack(spacing: 0) {
          if !navigation.sidebarHidden {
            Sidebar(navigation: navigation)
              .frame(width: HubMetrics.sidebarWidth)
              .transition(.move(edge: .leading).combined(with: .opacity))
          }
          panel
            .padding(.leading, navigation.sidebarHidden ? Wisper.Space.s : 0)
            .padding([.trailing, .bottom], Wisper.Space.s)
        }
      }
      .ignoresSafeArea(edges: .top)
      .animation(Wisper.Motion.smooth, value: navigation.sidebarHidden)
    }
    .modal(isPresented: $navigation.showsSettings) {
      SettingsScreen(shortcuts: AnyView(ShortcutsEditor()), onClose: { navigation.showsSettings = false })
        .frame(maxWidth: HubMetrics.settingsSize.width, maxHeight: HubMetrics.settingsSize.height)
        .modalSurface()
    }
  }

  private var panel: some View {
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.panel, style: .continuous)
    return VStack(spacing: 0) {
      notices
      screen
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Wisper.Color.panel, in: shape)
    .clipShape(shape)
    .overlay { shape.strokeBorder(Wisper.Color.border, lineWidth: Wisper.Stroke.hairline) }
  }

  @ViewBuilder private var screen: some View {
    switch navigation.section {
    case .home: HomeScreen()
    case .meetings: MeetingsScreen(selection: $navigation.meeting)
    case .dictionary: DictionaryScreen()
    case .snippets: SnippetsScreen()
    case .style: StyleScreen()
    }
  }

  /// Things the person should know whatever screen is open.
  @ViewBuilder private var notices: some View {
    let showsShortcutNotice = controls.needsAccessibility
    let error = model.errorMessage
    // The Meetings screen says this itself.
    let meetingProblem = navigation.section == .meetings ? nil : model.meetings.lastError
    if showsShortcutNotice || error != nil || meetingProblem != nil {
      VStack(spacing: Wisper.Space.s) {
        if showsShortcutNotice {
          Banner(
            .warning,
            title: "Your shortcuts are off",
            message:
              "Open Wisper needs Accessibility access to notice your shortcut keys and to type for you."
          ) {
            Button("Turn on") { controls.requestPermission(.accessibility) }
              .buttonStyle(.wisper(.tertiary, size: .small))
          }
        }
        if let error {
          Banner(.error, title: error) {
            IconButton("xmark", label: "Dismiss", size: .small) { model.errorMessage = nil }
          }
        }
        if let meetingProblem {
          Banner(.warning, title: meetingProblem) {
            IconButton("xmark", label: "Dismiss", size: .small) { model.meetings.lastError = nil }
          }
        }
      }
      .padding([.horizontal, .top], Wisper.Space.l)
      .transition(.opacity)
    }
  }
}

enum HubMetrics {
  static let sidebarWidth: CGFloat = 224
  static let settingsSize = CGSize(width: 960, height: 640)
  /// The height of the top strip when the window has no title bar to match (snapshots).
  static let minimumStrip: CGFloat = 32
  /// Room for the close, minimise and zoom buttons at the left of the strip.
  static let windowButtons: CGFloat = 76
}

/// The strip across the top of the hub, level with the window buttons: the
/// sidebar switch on the left and the theme choice on the right. The rest of
/// it is empty, so the window can be dragged by it.
struct TitleStrip: View {
  @Bindable var navigation: HubNavigation

  var body: some View {
    HStack(spacing: Wisper.Space.s) {
      IconButton(
        "sidebar.left",
        label: navigation.sidebarHidden ? "Show the sidebar" : "Hide the sidebar",
        size: .small
      ) {
        navigation.sidebarHidden.toggle()
      }
      .padding(.leading, navigation.isFullScreen ? Wisper.Space.m : HubMetrics.windowButtons)
      Spacer()
      Menu {
        Picker("Theme", selection: $navigation.theme) {
          ForEach(HubNavigation.Theme.allCases) { theme in
            Label(theme.title, systemImage: theme.symbol).tag(theme)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } label: {
        Image(systemName: navigation.theme.symbol)
          .wisperText(.caption, color: Wisper.Color.textPrimary)
          .frame(width: 26, height: 26)
          .hoverHighlight(radius: Wisper.Radius.small)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Theme")
      .accessibilityLabel("Theme")
      .padding(.trailing, Wisper.Space.m)
    }
    .frame(maxHeight: .infinity)
  }
}

/// The left column of the hub: the name, the sections, a tip, Settings and Help.
struct Sidebar: View {
  @Environment(AppModel.self) private var model
  @Bindable var navigation: HubNavigation
  @State private var showsHelp = false

  var body: some View {
    VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
      Wordmark()
        .padding(.horizontal, Wisper.Space.m)
        .padding(.top, Wisper.Space.m)
        .padding(.bottom, Wisper.Space.xl)
      ForEach(HubNavigation.Section.allCases) { section in
        NavItem(
          section.title,
          systemImage: section.symbol,
          isSelected: navigation.section == section,
          badge: section == .meetings && model.meetings.isRecording ? "Live" : nil
        ) {
          navigation.show(section)
        }
      }
      Spacer(minLength: Wisper.Space.l)
      if let tipKeys {
        SidebarCard(keys: tipKeys, navigation: navigation)
          .padding(.bottom, Wisper.Space.s)
      }
      Hairline().padding(.bottom, Wisper.Space.xs)
      NavItem("Settings", systemImage: "gearshape", isSelected: false) { navigation.showsSettings = true }
      NavItem("Help", systemImage: "questionmark.circle", isSelected: false) { showsHelp = true }
        .popover(isPresented: $showsHelp, arrowEdge: .trailing) {
          HelpMenu(navigation: navigation) { showsHelp = false }
        }
    }
    .padding(.horizontal, Wisper.Space.m)
    .padding(.bottom, Wisper.Space.m)
  }

  /// The hands-free tip, until it is dismissed. (A missing key is the Home screen's and the pill's to say.)
  private var tipKeys: [String]? {
    guard !navigation.tipDismissed, let combo = model.settings.shortcut(for: .handsFree), !combo.isEmpty
    else {
      return nil
    }
    return combo.keyCaps
  }
}

/// The small card above Settings in the sidebar: a tip about dictating hands-free.
struct SidebarCard: View {
  /// The key caps of the hands-free shortcut.
  let keys: [String]
  let navigation: HubNavigation

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.card, style: .continuous)
    VStack(alignment: .leading, spacing: Wisper.Space.s) {
      HStack(alignment: .top) {
        Text("Talk hands-free").wisperText(.bodyStrong)
        Spacer(minLength: Wisper.Space.xs)
        IconButton("xmark", label: "Dismiss this tip", size: .small) { navigation.tipDismissed = true }
          .padding([.top, .trailing], -Wisper.Space.xs)
      }
      KeyCapRow(keys)
      Text("Press once to start dictating. Press again when you are done.")
        .wisperText(.caption)
        .fixedSize(horizontal: false, vertical: true)
      Button("See all shortcuts") { navigation.showsSettings = true }
        .buttonStyle(.wisper(.secondary, size: .small))
        .padding(.top, Wisper.Space.xs)
    }
    .padding(Wisper.Space.l)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Wisper.Color.raised, in: shape)
    .overlay { shape.strokeBorder(Wisper.Color.border, lineWidth: Wisper.Stroke.hairline) }
  }
}

/// The few places Help leads to.
private struct HelpMenu: View {
  @Environment(AppModel.self) private var model
  let navigation: HubNavigation
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
      NavItem("Shortcuts and settings", systemImage: "keyboard", isSelected: false) {
        close()
        navigation.showsSettings = true
      }
      if let folder = model.host.dataFolder {
        NavItem("Show my data in Finder", systemImage: "folder", isSelected: false) {
          close()
          model.host.reveal(folder)
        }
      }
      NavItem("Show the tip again", systemImage: "lightbulb", isSelected: false) {
        close()
        navigation.tipDismissed = false
      }
    }
    .padding(Wisper.Space.s)
    .frame(width: 260)
    .environment(\.wisperIdiom, .mac)
  }
}
