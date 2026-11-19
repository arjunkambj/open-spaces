import Foundation
import Testing
import WisperDomain
import WisperEngine

@testable import WisperPhone

@MainActor
@Suite struct PhoneSessionTests {
  @Test func readsTheLaunchArguments() {
    #expect(PhoneSession.Launch(arguments: ["OpenWisper"]) == PhoneSession.Launch())

    let demo = PhoneSession.Launch(arguments: ["OpenWisper", "-x", "--demo"])
    #expect(demo.demo)
    #expect(demo.scene == nil)

    let scene = PhoneSession.Launch(arguments: ["OpenWisper", "--scene", "meetings"])
    #expect(scene.demo)
    #expect(scene.scene == "meetings")

    #expect(PhoneSession.Launch(arguments: ["--scene"]).scene == nil)
  }

  @Test func everyDemoSceneCanBeReached() async {
    for scene in DemoScene.allCases {
      let session = PhoneSession(model: scene.model())
      await session.start()
      await scene.prepare(session)
      switch scene {
      case .dictateRecording: #expect(session.dictation.isRecording)
      case .dictateWorking: #expect(session.dictation.phase == .processing(mode: .dictation))
      case .dictateResult: #expect(session.dictation.result != nil)
      case .dictateNothingHeard: #expect(session.dictation.problem == .nothingHeard)
      case .dictateNoKey: #expect(session.dictation.problem == .missingKey)
      case .dictateNoMicrophone: #expect(session.dictation.problem == .microphoneDenied)
      case .dictateFailed:
        guard case .failed(_, .some) = session.dictation.problem else {
          Issue.record("The failed scene offers no retry.")
          continue
        }
      case .dictateEmpty: #expect(session.dictation.earlier.isEmpty)
      case .firstRun: #expect(!session.model.settings.isOnboarded)
      case .keyboard: #expect(session.libraryPath == [.keyboard])
      case .meetings: #expect(session.tab == .meetings)
      case .meeting: #expect(session.meeting != nil)
      case .linkQuestion: #expect(session.meetingRequest?.title == "Weekly product sync")
      case .history: #expect(session.tab == .history)
      case .library: #expect(session.tab == .library)
      case .settings: #expect(session.tab == .settings)
      case .dictate: #expect(session.tab == .dictate)
      }
      session.dictation.cancel()
    }
  }

  /// The app itself sets a scene up from inside `start`, where waiting for `start` would
  /// wait forever. The time limit turns such a mistake into a failure.
  @Test(.timeLimit(.minutes(1)))
  func everyDemoSceneOpensFromTheLaunchArguments() async {
    for scene in DemoScene.allCases {
      let session = PhoneSession(launch: PhoneSession.Launch(arguments: ["--scene", scene.rawValue]))
      await session.start()
      #expect(session.model.isLoaded, "\(scene.rawValue)")
      if scene == .linkQuestion { #expect(session.meetingRequest != nil) }
      session.dictation.cancel()
    }
  }

  @Test func theKeyboardsDictationLinkStartsAndThenFinishes() async throws {
    let rig = await Rig()
    rig.session.tab = .settings

    #expect(await rig.session.open(try rig.ticketed(.toggleDictation)))
    #expect(rig.session.tab == .dictate)
    #expect(rig.dictation.isRecording)

    await rig.session.open(try rig.ticketed(.toggleDictation))
    #expect(rig.dictation.result != nil)
  }

  @Test func aDictationLinkWithoutATicketOnlyShowsTheButton() async throws {
    let rig = await Rig()
    rig.session.tab = .settings
    let plain = WisperLink.toggleDictation.url

    #expect(await rig.session.open(plain))
    #expect(rig.session.tab == .dictate)
    #expect(!rig.dictation.isRecording)
    #expect(rig.capture.requests.isEmpty)

    // Nor does it finish a recording the person started.
    await rig.dictation.toggle()
    await rig.session.open(plain)
    await rig.session.open(WisperLink.toggleDictation.url(ticket: "not-a-ticket-not-a-ticket-not-a-ticket"))
    #expect(rig.dictation.isRecording)
    rig.dictation.cancel()
  }

  @Test func aTicketWorksOnce() async throws {
    let rig = await Rig()
    let link = try rig.ticketed(.toggleDictation)

    await rig.session.open(link)
    #expect(rig.dictation.isRecording)
    // The same link again, as a page that saw it might replay it.
    await rig.session.open(link)
    #expect(rig.dictation.isRecording)
    rig.dictation.cancel()
  }

  @Test func aMeetingLinkWithoutATicketAsksFirst() async throws {
    let rig = await Rig()
    let link = WisperLink.startMeeting(title: "Standup").url

    await rig.session.open(link)
    #expect(!rig.model.meetings.isRecording)
    #expect(rig.capture.requests.isEmpty)
    #expect(rig.session.meetingRequest?.title == "Standup")

    // One question at a time.
    await rig.session.open(WisperLink.startMeeting(title: "Another").url)
    #expect(rig.session.meetingRequest?.title == "Standup")

    rig.session.answerMeetingRequest(allow: true)
    #expect(rig.session.meetingRequest == nil)
    #expect(await eventually { rig.model.meetings.live?.title == "Standup" })
    #expect(rig.session.tab == .meetings)

    // Nothing to ask while a meeting is being recorded.
    await rig.session.open(link)
    #expect(rig.session.meetingRequest == nil)
    await rig.model.meetings.stop()
  }

  @Test func afterANoTheQuestionStaysAway() async throws {
    let rig = await Rig()
    let link = WisperLink.startMeeting(title: nil).url

    await rig.session.open(link)
    rig.session.answerMeetingRequest(allow: false)
    #expect(rig.session.meetingRequest == nil)

    await rig.session.open(link)
    #expect(rig.session.meetingRequest == nil)
    #expect(!rig.model.meetings.isRecording)
  }

  @Test func aStopLinkWithoutATicketIsIgnored() async throws {
    let rig = await Rig()
    try await rig.model.meetings.start(title: "Standup")
    rig.session.tab = .dictate

    await rig.session.open(WisperLink.stopMeeting.url)
    #expect(rig.model.meetings.isRecording)
    #expect(rig.session.tab == .dictate)

    await rig.session.open(try rig.ticketed(.stopMeeting))
    #expect(!rig.model.meetings.isRecording)
    #expect(rig.session.tab == .meetings)
  }

  @Test func linksThatAreNotOursAreLeftAlone() async throws {
    let rig = await Rig()
    #expect(await !rig.session.open(try #require(URL(string: "https://example.com/dictation/toggle"))))
    #expect(await !rig.session.open(try #require(URL(string: "openwisper://nothing/here"))))
    #expect(rig.session.tab == .dictate)
    #expect(!rig.dictation.isRecording)
  }

  @Test func meetingLinksStartShowAndStop() async throws {
    let rig = await Rig()

    await rig.session.follow(.startMeeting(title: "Standup"), trusted: true)
    #expect(rig.session.tab == .meetings)
    #expect(rig.model.meetings.live?.title == "Standup")
    let id = try #require(rig.model.meetings.live?.meetingID)

    // Showing a meeting needs no ticket.
    rig.session.tab = .dictate
    await rig.session.open(WisperLink.showMeeting(id).url)
    #expect(rig.session.tab == .meetings)
    #expect(rig.session.meeting == id)

    rig.session.tab = .dictate
    await rig.session.follow(.stopMeeting, trusted: true)
    #expect(!rig.model.meetings.isRecording)
    #expect(rig.session.tab == .meetings)
    #expect(rig.session.meeting == nil)
    #expect(await !rig.session.stopMeeting())
  }

  @Test func aMeetingWaitsForTheDictationToLetGoOfTheMicrophone() async {
    let rig = await Rig()
    await rig.dictation.toggle()

    await rig.session.startMeeting()
    #expect(!rig.dictation.isRecording)
    #expect(rig.dictation.result != nil)
    #expect(rig.model.meetings.isRecording)
    await rig.model.meetings.stop()
  }

  @Test func aRecordingShowsOnTheLockScreenUntilItStops() async {
    let rig = await Rig()
    // Starting up clears a notice that a crash may have left behind.
    #expect(await eventually { rig.lockScreen.titles == [nil] })

    await rig.session.startMeeting(title: "Standup")
    #expect(await eventually { rig.lockScreen.titles == [nil, "Standup"] })

    await rig.session.stopMeeting()
    #expect(await eventually { rig.lockScreen.titles == [nil, "Standup", nil] })
  }

  @Test func aMeetingAsksForTheMicrophoneTheFirstTime() async {
    let rig = await Rig(microphone: .notDetermined, answer: .granted)

    await rig.session.startMeeting()
    #expect(rig.permissions.requests == 1)
    #expect(rig.model.meetings.isRecording)
    await rig.model.meetings.stop()
  }

  @Test func aMeetingThatCannotStartSaysWhy() async {
    // The real capture refuses like this when the microphone was denied.
    let rig = await Rig(
      microphone: .denied,
      capture: FakeAudioCapture(failure: .permissionDenied(.microphone))
    )

    await rig.session.startMeeting()
    #expect(rig.session.tab == .meetings)
    #expect(!rig.model.meetings.isRecording)
    #expect(rig.model.meetings.lastError?.contains("Microphone") == true)
  }

  @Test func nothingRunsBeforeTheFirstRunSetupIsDone() async {
    let rig = await Rig(settings: Settings())

    await rig.session.follow(.toggleDictation, trusted: true)
    await rig.session.follow(.startMeeting(title: nil), trusted: true)
    await rig.session.startDictation()
    #expect(!rig.dictation.isRecording)
    #expect(!rig.model.meetings.isRecording)
    #expect(rig.capture.requests.isEmpty)
  }

  @Test func startDictationDoesNotStopOneThatIsRunning() async {
    let rig = await Rig()

    await rig.session.startDictation()
    await rig.session.startDictation()
    #expect(rig.dictation.isRecording)
    rig.dictation.cancel()
  }

  @Test func leavingTheDictateTabFinishesTheRecording() async {
    let rig = await Rig()
    await rig.dictation.toggle()

    rig.session.tab = .history
    let finished = await eventually { rig.dictation.result != nil }
    #expect(finished)
    #expect(!rig.dictation.isRecording)
  }

  @Test func leavingTheAppFinishesTheDictationButNotTheMeeting() async throws {
    let rig = await Rig()
    await rig.dictation.toggle()

    rig.session.leftTheScreen()
    #expect(await eventually { rig.dictation.result != nil })
    #expect(rig.copied.texts == ["Call the dentist tomorrow morning."])

    try await rig.model.meetings.start()
    rig.session.leftTheScreen()
    try? await Task.sleep(for: .milliseconds(30))
    #expect(rig.model.meetings.isRecording)
    await rig.model.meetings.stop()
  }

  @Test func copiesTheLastDictation() async {
    let empty = await Rig()
    #expect(await !empty.session.copyLastDictation())

    let old = Dictation(
      createdAt: Date().addingTimeInterval(-60),
      rawText: "x",
      text: "From last week.",
      duration: 2
    )
    let broken = Dictation(rawText: "", text: "", duration: 1, failure: "offline")
    let rig = await Rig(dictations: [old, broken])
    #expect(await rig.session.copyLastDictation())
    #expect(rig.copied.texts == ["From last week."])

    await rig.dictation.toggle()
    await rig.dictation.toggle()
    #expect(await rig.session.copyLastDictation())
    #expect(rig.copied.last == "Call the dentist tomorrow morning.")
  }

  @Test func theTextTargetCopiesAndRemembers() async {
    let copied = Copied()
    let target = ClipboardTextTarget(clipboard: copied.clipboard)

    #expect(await target.latest == nil)
    #expect(await target.context() == DictationContext(category: .other))
    #expect(await target.selectedText() == nil)

    await target.insert("First.")
    await target.insert("Second.")
    #expect(copied.texts == ["First.", "Second."])
    #expect(await target.latest == "Second.")
  }
}
