import Foundation
import SpacesDomain
import SpacesEngine
import SpacesKeyboard
import SpacesLive
import SpacesUI
import SwiftUI

/// A state of the app on made-up data, reached without touching the phone's microphone,
/// network or files. Used for screenshots (`--demo --scene <name>`) and for snapshots.
enum DemoScene: String, CaseIterable, Sendable {
  case dictate
  case dictateEmpty = "dictate-empty"
  case dictateRecording = "dictate-recording"
  case dictateWorking = "dictate-working"
  case dictateResult = "dictate-result"
  case dictateFailed = "dictate-failed"
  case dictateNothingHeard = "dictate-nothing-heard"
  case dictateNoKey = "dictate-no-key"
  case dictateNoMicrophone = "dictate-no-microphone"
  case meetings, meeting, history, library, settings, keyboard
  case linkQuestion = "link-question"
  case firstRun = "first-run"

  /// The app model the scene starts from.
  @MainActor
  func model() -> AppModel {
    switch self {
    case .dictateEmpty:
      Self.model(library: InMemoryLibrary(settings: Settings(userName: "Alex", onboardedAt: Date())))
    case .dictateWorking:
      Self.model(
        transcriber: FakeTranscriber { _ in
          try await Task.sleep(for: .seconds(3_600))
          return Transcript(text: "")
        }
      )
    case .dictateFailed:
      Self.model(transcriber: FakeTranscriber { _ in throw SpacesError.network("The connection was lost.") })
    case .dictateNothingHeard:
      Self.model(transcriber: FakeTranscriber(text: ""))
    case .dictateResult:
      Self.model(
        says: "Hi Priya, thanks for sending the plan. Thursday at three works for me. I'll bring the numbers."
      )
    case .dictateNoKey:
      .demo(hasAPIKey: false)
    case .dictateNoMicrophone:
      .demo(permissions: [.microphone: .denied])
    case .firstRun:
      .demo(onboarded: false, hasAPIKey: false, permissions: [:])
    case .dictate, .dictateRecording, .meetings, .meeting, .history, .library, .settings, .keyboard,
      .linkQuestion:
      .demo()
    }
  }

  /// Brings a started session to the scene.
  @MainActor
  func prepare(_ session: PhoneSession) async {
    let dictation = session.dictation
    switch self {
    case .dictate, .dictateEmpty, .dictateNoKey, .dictateNoMicrophone, .firstRun:
      break
    case .dictateRecording:
      await dictation.start()
    case .dictateWorking:
      await dictation.start()
      Task { await dictation.stop() }
      await Self.wait { dictation.phase == .processing(mode: .dictation) }
    case .dictateResult, .dictateNothingHeard:
      await dictation.start()
      await dictation.stop()
    case .dictateFailed:
      await dictation.start()
      await dictation.stop()
      // The failed entry reaches the model's copy of the library a moment later.
      await Self.wait { session.model.dictations.first?.failed == true }
    case .meetings:
      session.tab = .meetings
    case .meeting:
      session.tab = .meetings
      session.meeting = session.model.meetingList.first?.id
    case .linkQuestion:
      // What a link from a web page leads to: it has no ticket, so the app asks.
      session.ask(toRecord: "Weekly product sync")
    case .history:
      session.tab = .history
    case .library:
      session.tab = .library
    case .settings:
      session.tab = .settings
    case .keyboard:
      session.tab = .library
      session.libraryPath = [.keyboard]
    }
  }

  /// The demo model with one fake swapped for another. `says` is what a dictation comes out as.
  @MainActor
  private static func model(
    library: InMemoryLibrary = SampleData.library(),
    says text: String = "This is a demo dictation.",
    transcriber: (any Transcriber)? = nil
  ) -> AppModel {
    AppModel(
      AppModel.Dependencies(
        library: library,
        secrets: InMemorySecretStore(apiKey: "sk-demo"),
        capture: FakeAudioCapture(),
        transcriber: transcriber ?? FakeTranscriber(text: text),
        languageModel: FakeLanguageModel(text: text),
        target: FakeTextTarget(),
        permissions: FakePermissions(statuses: [.microphone: .granted]),
        checkAPIKey: { _ in }
      )
    )
  }

  @MainActor
  private static func wait(until condition: @MainActor () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}

/// The phone's own screens as snapshot cases, for `spaces-phone-snapshots`.
public enum PhoneSnapshots {
  /// One case per state worth looking at. Async because some states are reached by
  /// running a (fake) dictation first.
  @MainActor
  public static func cases() async -> [SnapshotCase] {
    var cases: [SnapshotCase] = []
    for scene in DemoScene.allCases {
      guard let view = view(for: scene) else { continue }
      let session = PhoneSession(model: scene.model())
      await session.start()
      await scene.prepare(session)
      cases.append(
        SnapshotCase("phone-\(scene.rawValue)", canvas: .phone, model: { session.model }) {
          view.environment(session)
        }
      )
    }
    return cases + extras
  }

  /// The view a scene shows, for the scenes that are about one of the phone's own screens.
  @MainActor
  private static func view(for scene: DemoScene) -> AnyView? {
    switch scene {
    case .dictate, .dictateEmpty, .dictateRecording, .dictateWorking, .dictateResult, .dictateFailed,
      .dictateNothingHeard, .dictateNoKey, .dictateNoMicrophone:
      AnyView(DictateScreen())
    case .library: AnyView(LibraryScreen())
    case .keyboard: AnyView(KeyboardSetupScreen())
    case .firstRun: AnyView(KeyboardSetupStep())
    // Shared screens have their own snapshots in SpacesUI.
    case .meetings, .meeting, .history, .settings, .linkQuestion: nil
    }
  }

  /// The keyboard in its states, and the notice a recording puts on the Lock Screen.
  @MainActor
  private static var extras: [SnapshotCase] {
    let quiet = KeyboardHost(
      insert: { _ in },
      deleteBackward: {},
      nextKeyboard: {},
      open: { _ in false },
      hasFullAccess: { false }
    )
    let models: [(String, KeyboardModel)] = [
      ("keyboard", .sample),
      ("keyboard-new", .sample(snippets: [], latest: nil)),
      ("keyboard-no-access", .sample(problem: .needsFullAccess)),
      ("keyboard-no-folder", .sample(problem: .noSharedFolder)),
      ("keyboard-hint", KeyboardModel(library: InMemoryLibrary(), host: quiet)),
    ]
    models.last?.1.insertLatest()
    let keyboards = models.map { name, model in
      SnapshotCase(name, canvas: .custom(width: 393, height: KeyboardPanel.height)) {
        KeyboardPanel(model: model)
      }
    }
    let banner = SnapshotCase("lock-screen-recording", canvas: .custom(width: 393, height: 84)) {
      MeetingBanner(title: "Weekly product sync", startedAt: Date().addingTimeInterval(-754)) {
        StopLabel()
      }
    }
    return keyboards + [banner]
  }
}
