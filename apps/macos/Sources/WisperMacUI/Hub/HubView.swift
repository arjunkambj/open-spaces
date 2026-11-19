import SwiftUI
import WisperDomain
import WisperEngine
import WisperMac
import WisperUI

/// The content of the main window: first-run setup until it is done, then the
/// sidebar and the selected screen side by side, with Settings as a card on top.
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
      // Two flat columns that run the full height of the window, a hairline between them.
      HStack(spacing: 0) {
        if !navigation.sidebarHidden {
          HStack(spacing: 0) {
            Sidebar(navigation: navigation)
              .padding(.top, strip)
              .frame(width: HubMetrics.sidebarWidth)
            Rectangle()
              .fill(Wisper.Color.border)
              .frame(width: Wisper.Stroke.hairline)
              .accessibilityHidden(true)
          }
          .transition(.move(edge: .leading).combined(with: .opacity))
        }
        panel
          .padding(.top, strip)
          .background(Wisper.Color.panel)
      }
      .overlay(alignment: .top) {
        TitleStrip(navigation: navigation)
          .frame(height: strip)
      }
      .ignoresSafeArea(edges: .top)
      .animation(Wisper.Motion.smooth, value: navigation.sidebarHidden)
    }
    .modal(isPresented: $navigation.showsSettings) {
      SettingsScreen(
        shortcuts: AnyView(ShortcutsEditor()),
        onClose: { navigation.showsSettings = false },
        appearance: AnyView(AppearanceRow(navigation: navigation))
      )
      .frame(maxWidth: HubMetrics.settingsSize.width, maxHeight: HubMetrics.settingsSize.height)
      .modalSurface()
    }
  }

  private var panel: some View {
    VStack(spacing: 0) {
      notices
      screen
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
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

/// The strip across the top of the hub, level with the window buttons: only the sidebar
/// switch. The rest of it is empty, so the window can be dragged by it.
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
    }
    .frame(maxHeight: .infinity)
  }
}

/// The left column of the hub: the name, the sections, and Settings at the foot.
struct Sidebar: View {
  @Environment(AppModel.self) private var model
  @Bindable var navigation: HubNavigation

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
      NavItem("Settings", systemImage: "gearshape", isSelected: false) { navigation.showsSettings = true }
    }
    .padding(.horizontal, Wisper.Space.m)
    .padding(.bottom, Wisper.Space.m)
  }
}

/// The row of Settings that chooses light, dark or the Mac's own look. The hub hands it to the
/// settings screen, which shows it under "App".
struct AppearanceRow: View {
  @Bindable var navigation: HubNavigation

  var body: some View {
    SettingRow("Appearance") {
      Dropdown(
        "Appearance",
        selection: $navigation.theme,
        options: HubNavigation.Theme.allCases,
        title: \.title
      )
    }
  }
}
