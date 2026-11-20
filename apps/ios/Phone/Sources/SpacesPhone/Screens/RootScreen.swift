import SpacesDomain
import SpacesEngine
import SpacesUI
import SwiftUI

/// The whole iPhone app as one view: first-run setup, then the five tabs.
///
///     WindowGroup { RootScreen() }
public struct RootScreen: View {
  private let session: PhoneSession
  @Environment(\.scenePhase) private var scenePhase

  @MainActor
  public init() {
    session = .shared
  }

  public var body: some View {
    content
      .environment(session.model)
      .environment(session)
      .environment(\.phoneDevice, session.device)
      .tint(Spaces.Color.accent)
      .task { await session.start() }
      .onOpenURL { url in
        Task { await session.open(url) }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .background { session.leftTheScreen() }
      }
      // A link from outside Spaces wants the microphone on. The person decides.
      .alert("Record a meeting?", isPresented: isAsking, presenting: session.meetingRequest) { _ in
        Button("Start recording") { session.answerMeetingRequest(allow: true) }
        Button("Not now", role: .cancel) { session.answerMeetingRequest(allow: false) }
      } message: { request in
        Text(Self.question(request))
      }
  }

  /// The alert goes away when the question is answered; only its buttons answer it.
  private var isAsking: Binding<Bool> {
    Binding(get: { session.meetingRequest != nil }, set: { _ in })
  }

  private static func question(_ request: PhoneSession.MeetingRequest) -> String {
    let what =
      request.title.map { "a meeting called “\($0)”" } ?? "a meeting"
    return "A link asked Spaces to record \(what). Recording uses the microphone."
  }

  @ViewBuilder private var content: some View {
    if !session.model.isLoaded {
      // The same picture as the launch screen, so nothing flashes while the library loads.
      ZStack {
        Spaces.Color.panel.ignoresSafeArea()
        SpacesGlyph(size: 32)
      }
    } else if !session.model.settings.isOnboarded {
      OnboardingFlow(practice: AnyView(KeyboardSetupStep()))
    } else {
      TabShell(session: session)
    }
  }
}

/// The five tabs. Shared screens come from `SpacesUI`; Dictate and Library are the phone's own.
private struct TabShell: View {
  @Bindable var session: PhoneSession

  var body: some View {
    TabView(selection: $session.tab) {
      DictateScreen()
        .tabItem { Label("Dictate", systemImage: "mic.fill") }
        .tag(PhoneSession.Tab.dictate)

      NavigationStack {
        MeetingsScreen(selection: $session.meeting)
          .navigationBarHidden()
      }
      .tabItem { Label("Meetings", systemImage: "person.2.fill") }
      .tag(PhoneSession.Tab.meetings)

      HomeScreen()
        .tabItem { Label("History", systemImage: "clock.fill") }
        .tag(PhoneSession.Tab.history)

      NavigationStack(path: $session.libraryPath) {
        LibraryScreen()
          .navigationBarHidden()
          .navigationDestination(for: PhoneSession.LibraryPage.self) { page in
            LibraryScreen.destination(page)
              .pushedPage()
          }
      }
      .tabItem { Label("Library", systemImage: "books.vertical.fill") }
      .tag(PhoneSession.Tab.library)

      SettingsScreen(shortcuts: nil, onClose: nil)
        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        .tag(PhoneSession.Tab.settings)
    }
  }
}

extension View {
  /// Hides the system navigation bar: every `Page` draws its own large title.
  fileprivate func navigationBarHidden() -> some View {
    #if os(iOS)
      toolbar(.hidden, for: .navigationBar)
    #else
      self
    #endif
  }

  /// A page pushed onto a stack keeps the system bar for its back button, but lets the
  /// page's own background and title show through it.
  fileprivate func pushedPage() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    #else
      self
    #endif
  }
}
