import AppKit
import WisperDomain
import WisperEngine
import WisperMac
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
  /// Links that arrived before the library was read, each with whether its ticket was good.
  private var waitingLinks: [(link: WisperLink, ticketIsValid: Bool)] = []
  private var isReady = false
  private var gate = LinkGate()

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
      // The person may have taken the app out of Login Items since the last run.
      parts.controls.noteLaunchAtLogin(LaunchAtLogin.status)
      // Opened by the person: show the window. Opened by the Mac at login: stay in the menu bar.
      if !openedAtLogin || !parts.model.settings.isOnboarded { hub.show() }
      for waiting in waitingLinks { receive(waiting.link, ticketIsValid: waiting.ticketIsValid) }
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
    for url in urls {
      guard let link = WisperLink(url) else { continue }
      // A ticket is looked at once, when its link arrives. Only the bundled tool can make one.
      let ticketIsValid =
        link.needsTrust
        && parts.model.host.dataFolder.map { LinkTicket.redeem(WisperLink.ticket(in: url), in: $0) } == true
      if isReady {
        receive(link, ticketIsValid: ticketIsValid)
      } else if waitingLinks.count < Self.mostWaitingLinks {
        waitingLinks.append((link, ticketIsValid))
      }
    }
  }

  /// A link that opens the app arrives before the library is read. A handful is plenty.
  private static let mostWaitingLinks = 8

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

  /// Decides what to do with a link (`LinkGate` has the rules) and does it.
  private func receive(_ link: WisperLink, ticketIsValid: Bool) {
    let model = parts.model
    let decision = gate.decide(
      link,
      ticketIsValid: ticketIsValid,
      isSetUp: model.isLoaded && model.settings.isOnboarded,
      isRecordingMeeting: model.meetings.isRecording
    )
    switch decision {
    case .ignore:
      break
    case .act:
      follow(link)
    case .ask:
      guard let hub else {
        gate.answered(allowed: false)
        return
      }
      Task {
        let allowed = await hub.confirm(
          "A link from outside Open Wisper wants to start recording a meeting.",
          yes: "Allow",
          no: "Don’t allow"
        )
        gate.answered(allowed: allowed)
        if allowed { follow(link) }
      }
    }
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
      parts.controls.startMeeting(title: title)
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
