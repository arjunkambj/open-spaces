import Foundation
import Observation
import WisperAI
import WisperAudio
import WisperDomain
import WisperEngine
import WisperKeyboard
import WisperStore

/// The running iPhone app: its `AppModel`, where the person is in it, and everything that
/// can be asked of it from outside a screen (links, Shortcuts, Siri, the keyboard).
///
/// There is one per process, `PhoneSession.shared`. `RootScreen` shows it; the App Intents
/// and `openwisper://` links call its methods.
@MainActor
@Observable
public final class PhoneSession {
  /// The tabs at the bottom of the screen.
  public enum Tab: String, Hashable, CaseIterable, Sendable {
    case dictate, meetings, history, library, settings
  }

  /// The pages that open from the Library tab.
  public enum LibraryPage: String, Hashable, CaseIterable, Sendable, Identifiable {
    case dictionary, snippets, style, keyboard
    public var id: String { rawValue }
  }

  /// How the app was started. Read from the launch arguments.
  public struct Launch: Equatable, Sendable {
    /// Run on made-up data, in memory. Nothing is read from or written to the phone.
    public var demo = false
    /// In a demo, the state to open in, by name: `dictate-recording`, `meetings`,
    /// `first-run`... An unknown name is the plain demo.
    public var scene: String?

    public init() {}

    /// Reads `--demo` and `--scene <name>` (which implies a demo). Anything else is ignored.
    public init(arguments: [String]) {
      var rest = arguments[...]
      while let argument = rest.popFirst() {
        switch argument {
        case "--demo":
          demo = true
        case "--scene":
          scene = rest.popFirst()
          demo = true
        default:
          break
        }
      }
    }
  }

  /// A link asked to record a meeting and could not show that it comes from Open Wisper
  /// itself. It waits here for the person's yes or no.
  public struct MeetingRequest: Equatable, Sendable {
    /// The name the link gave the meeting, if any.
    public var title: String?
  }

  public let model: AppModel
  public let dictation: PhoneDictation

  /// The tab on screen. Leaving the Dictate tab finishes a recording, so the phone's one
  /// microphone is free for a meeting.
  public var tab: Tab = .dictate {
    didSet {
      guard oldValue == .dictate, tab != .dictate, dictation.isRecording else { return }
      Task { await dictation.stop() }
    }
  }
  /// The meeting open in the Meetings tab, or `nil` for the list.
  public var meeting: Meeting.ID?
  /// The pages pushed in the Library tab.
  public var libraryPath: [LibraryPage] = []
  /// The question to put to the person right now, if any. `answerMeetingRequest` clears it.
  public private(set) var meetingRequest: MeetingRequest?

  /// How long no new question is asked after the person said no, in seconds. A web page
  /// cannot fill the screen with dialogs.
  static let quietTime: TimeInterval = 60

  @ObservationIgnored let device: PhoneDevice
  @ObservationIgnored private let launch: Launch
  @ObservationIgnored private var starting: Task<Void, Never>?
  @ObservationIgnored private var followingMeeting: Task<Void, Never>?
  @ObservationIgnored private var quietUntil = Date.distantPast

  /// The app's one session, made from the launch arguments.
  public static let shared = PhoneSession(launch: Launch(arguments: ProcessInfo.processInfo.arguments))

  /// The real app, or a demo on made-up data when `launch.demo` is set.
  ///
  /// On a Mac it is always the demo: this package is built there only for its tests and
  /// snapshots, and those must never touch a person's real library.
  public convenience init(launch: Launch) {
    #if os(iOS)
      let model = launch.demo ? PhoneSession.demoModel(launch) : PhoneSession.liveModel(device: .live)
      self.init(model: model, device: .live, launch: launch)
    #else
      self.init(model: PhoneSession.demoModel(launch), device: .quiet, launch: launch)
    #endif
  }

  init(model: AppModel, device: PhoneDevice = .quiet, launch: Launch = Launch()) {
    self.model = model
    self.device = device
    self.launch = launch
    dictation = PhoneDictation(model: model, clipboard: device.clipboard)
  }

  /// Loads the library and picks up meetings a crash left unfinished. Safe to call again:
  /// every caller waits for the same one start.
  public func start() async {
    if starting == nil {
      starting = Task {
        await model.load()
        await model.meetings.recoverUnfinished()
        dictation.refresh()
        followMeeting()
        await applyLaunch()
      }
    }
    await starting?.value
  }

  /// The app left the screen. A dictation in progress is finished, so its text is ready
  /// (on the clipboard and for the keyboard) in the app the person went to. A meeting
  /// keeps recording.
  public func leftTheScreen() {
    guard dictation.isRecording else { return }
    let dictation = dictation
    device.finishInBackground { await dictation.stop() }
  }

  // MARK: Links

  /// Answers an `openwisper://` link. Returns `false` when the link is not one of ours.
  ///
  /// Any app or web page can open such a link, so one that would start the microphone or
  /// cut a recording short is only obeyed when it carries a valid `LinkTicket`, which the
  /// Open Wisper keyboard attaches. Without a ticket, a link that starts a meeting becomes a
  /// question (`meetingRequest`); one that starts dictation only shows the Dictate tab; one
  /// that stops a meeting does nothing. Links that only show something are always followed.
  @discardableResult
  public func open(_ url: URL) async -> Bool {
    guard let link = WisperLink(url) else { return false }
    // A ticket is used up by looking at it, so only a link that needs one is checked.
    let trusted = link.needsTrust && device.redeemTicket(WisperLink.ticket(in: url))
    await follow(link, trusted: trusted)
    return true
  }

  /// Does what a link says. `trusted` is whether it came with a valid ticket.
  func follow(_ link: WisperLink, trusted: Bool) async {
    guard await isSetUp() else { return }
    switch link {
    case .toggleDictation:
      // Showing the button is harmless. Pressing it is the person's to do, or the keyboard's.
      tab = .dictate
      guard trusted else { return }
      await dictation.toggle()
    case .startMeeting(let title):
      guard trusted else { return ask(toRecord: title) }
      await startMeeting(title: title)
    case .stopMeeting:
      guard trusted, await stopMeeting() else { return }
      // Show where the notes will appear.
      tab = .meetings
      meeting = nil
    case .showMeeting(let id):
      tab = .meetings
      meeting = id
    case .showHub:
      // The way in from the Lock Screen notice: go to what is being recorded.
      guard model.meetings.isRecording else { return }
      tab = .meetings
      meeting = nil
    }
  }

  /// The person answered the question in `meetingRequest`.
  public func answerMeetingRequest(allow: Bool) {
    guard let request = meetingRequest else { return }
    meetingRequest = nil
    guard allow else {
      quietUntil = Date().addingTimeInterval(Self.quietTime)
      return
    }
    Task { await startMeeting(title: request.title) }
  }

  /// One question at a time, none while a meeting is recorded, none right after a no.
  func ask(toRecord title: String?) {
    guard !model.meetings.isRecording, meetingRequest == nil, Date() >= quietUntil else { return }
    meetingRequest = MeetingRequest(title: title)
  }

  // MARK: Commands

  /// Shows the Dictate tab and starts recording (it keeps going if it already is).
  public func startDictation() async {
    guard await isSetUp() else { return }
    tab = .dictate
    await dictation.start()
  }

  /// Shows the Meetings tab and starts recording a meeting. When that cannot be done, the
  /// reason lands in `model.meetings.lastError`, which the Meetings screen shows.
  public func startMeeting(title: String? = nil) async {
    guard await isSetUp() else { return }
    tab = .meetings
    meeting = nil
    guard !model.meetings.isRecording else { return }
    // One microphone: let the dictation finish and let go of it first.
    if dictation.isRecording { await dictation.stop() }
    if model.permissions.status(.microphone) == .notDetermined {
      await model.permissions.request(.microphone)
    }
    do {
      try await model.meetings.start(title: title)
    } catch {
      model.meetings.lastError = error.localizedDescription
    }
  }

  /// Stops the meeting recording. Returns `false` when none was running.
  @discardableResult
  public func stopMeeting() async -> Bool {
    await start()
    guard model.meetings.isRecording else { return false }
    await model.meetings.stop()
    return true
  }

  /// Puts the most recent dictation on the clipboard. Returns `false` when there is none.
  @discardableResult
  public func copyLastDictation() async -> Bool {
    await start()
    var text = dictation.result?.text
    if text == nil {
      let recent = try? await model.library.dictations(search: nil, limit: 20)
      text = recent?.first { !$0.failed && !$0.text.isEmpty }?.text
    }
    guard let text, !text.isEmpty else { return false }
    device.clipboard.write(text)
    return true
  }

  // MARK: Inside

  /// Whether the first-run setup is behind us. Links and commands wait until it is.
  private func isSetUp() async -> Bool {
    await start()
    return model.settings.isOnboarded
  }

  /// Keeps the notice on the Lock Screen in step with the meeting being recorded, for as
  /// long as the app runs. The first pass also clears a notice a crash left behind.
  private func followMeeting() {
    followingMeeting = Task { [weak self] in
      var shown: MeetingEngine.Live?
      var isFirst = true
      while !Task.isCancelled {
        let changes: AsyncStream<Void>
        do {
          // The session is held only while it is looked at, not while waiting for a change.
          guard let self else { return }
          // Watching starts with the read, so no change slips in between.
          let (stream, change) = AsyncStream.makeStream(of: Void.self)
          changes = stream
          var live = withObservationTracking {
            self.model.meetings.live
          } onChange: {
            change.yield()
            change.finish()
          }
          // The transcript grows all the time; the notice only shows the title and the clock.
          live?.segments = []
          if isFirst || live != shown {
            await self.device.showRecording(live.map { (title: $0.title, startedAt: $0.startedAt) })
            shown = live
            isFirst = false
          }
        }
        for await _ in changes { break }
      }
    }
  }

  private func applyLaunch() async {
    guard launch.demo, let scene = launch.scene.flatMap(DemoScene.init(rawValue:)) else { return }
    await scene.prepare(self)
  }

  private static func demoModel(_ launch: Launch) -> AppModel {
    launch.scene.flatMap(DemoScene.init(rawValue:))?.model() ?? .demo()
  }

  /// The real adapters, wired together. The only place that happens on the phone.
  private static func liveModel(device: PhoneDevice) -> AppModel {
    let folder = SharedFolder()
    folder.adoptLibrary()
    let library = FileLibrary(root: folder.root)
    // The key stays in the app's own Keychain. The keyboard never needs it.
    let secrets = KeychainSecretStore()
    let openAI = OpenAI(
      secrets: secrets,
      baseURL: {
        let address = (try? await library.settings())?.apiBaseURL ?? ""
        return URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    )
    return AppModel(
      AppModel.Dependencies(
        library: library,
        secrets: secrets,
        capture: SystemAudioCapture(),
        transcriber: openAI.transcriber,
        languageModel: openAI.languageModel,
        target: ClipboardTextTarget(clipboard: device.clipboard),
        permissions: PhonePermissions(openSettings: device.openSettings),
        host: HostActions(),
        checkAPIKey: { key in try await openAI.check(key: key) }
      )
    )
  }
}
