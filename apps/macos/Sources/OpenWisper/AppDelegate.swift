import AppKit
import WisperDomain
import WisperEngine
import WisperMacUI

/// Starts the app and holds its long-lived parts: the model, the controls,
/// the main window, the pill and the menu bar item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let isDemo: Bool
  private let parts: Composition.Parts
  private var navigation: HubNavigation?
  private var hub: HubWindow?
  private var pill: PillPanel?
  private var statusItem: StatusItem?
  private var watches: [AnyObject] = []
  /// Links that arrived before the library was read.
  private var waitingLinks: [WisperLink] = []
  private var isReady = false

  init(parts: Composition.Parts, isDemo: Bool) {
    self.parts = parts
    self.isDemo = isDemo
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // A menu bar app until the main window opens.
    NSApp.setActivationPolicy(.accessory)
    let openedAtLogin = Self.wasOpenedAtLogin()

    let parts = parts
    // The demo remembers nothing between runs.
    let navigation = HubNavigation(defaults: isDemo ? nil : .standard)
    let hub = HubWindow(
      model: parts.model,
      controls: parts.controls,
      navigation: navigation,
      remembersFrame: !isDemo
    )
    self.navigation = navigation
    self.hub = hub

    parts.controls.open = { [weak self] destination in self?.open(destination) }
    NSApp.mainMenu = MainMenu.make(navigation: navigation, controls: parts.controls) { [weak hub] in
      hub?.show()
    }
    watches.append(Watch({ navigation.theme }) { theme in NSApp.appearance = theme.appearance })
    statusItem = StatusItem(model: parts.model, controls: parts.controls)
    let pill = PillPanel(model: parts.model, controls: parts.controls)
    pill.show()
    self.pill = pill
    OtherInstance.listen { [weak hub] in hub?.show() }

    Task {
      await parts.model.load()
      await parts.model.meetings.recoverUnfinished()
      // The shortcuts come on once setup is done (the last setup step turns them on to be tried).
      watches.append(
        Watch({ parts.model.settings.isOnboarded }) { isOnboarded in
          if isOnboarded { parts.controls.start() }
        }
      )
      isReady = true
      // Opened by the person: show the window. Opened by the Mac at login: stay in the menu bar.
      if !openedAtLogin || !parts.model.settings.isOnboarded { hub.show() }
      for link in waitingLinks { follow(link) }
      waitingLinks = []
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    hub?.show()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for link in urls.compactMap(WisperLink.init) {
      if isReady { follow(link) } else { waitingLinks.append(link) }
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let model = parts.model
    guard model.meetings.isRecording else { return .terminateNow }
    // Close the recording properly, so its last minutes are not left for the next launch to rescue.
    Task {
      await model.meetings.stop()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  // MARK: - Showing things

  private func open(_ destination: MacControls.Destination) {
    guard let navigation, let hub else { return }
    switch destination {
    case .hub: break
    case .settings: navigation.showsSettings = true
    case .meeting(let id): navigation.show(meeting: id)
    }
    hub.show()
  }

  private func follow(_ link: WisperLink) {
    switch link {
    case .showHub:
      open(.hub)
    case .showMeeting(let id):
      open(.meeting(id))
    case .toggleDictation:
      parts.controls.toggleHandsFree()
    case .startMeeting(let title):
      guard !parts.model.meetings.isRecording else { return }
      parts.model.run { model in _ = try await model.meetings.start(title: title) }
    case .stopMeeting:
      Task { await parts.model.meetings.stop() }
    }
  }

  /// Whether macOS started the app as a login item, rather than the person opening it.
  private static func wasOpenedAtLogin() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventID == kAEOpenApplication
    else { return false }
    return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
  }
}
