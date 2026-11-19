import Foundation
import Testing
import WisperDomain
import WisperEngine
import WisperMac

@testable import WisperMacUI

/// An app model on fakes, with the fakes kept at hand.
@MainActor
struct Stage {
  let model: AppModel
  let target = FakeTextTarget()
  let capture: FakeAudioCapture
  let library = SampleData.library()
  let controls: MacControls
  /// The places the controls asked the app to show.
  let opened = Opened()
  /// The sounds the controls played, in order. Nothing is really played.
  let heard = Heard()
  /// The shortcut monitor the controls were given, or `nil`. Never started: it watches no keys.
  let monitor: ShortcutMonitor?

  @MainActor
  final class Opened {
    var destinations: [MacControls.Destination] = []
  }

  @MainActor
  final class Heard {
    var sounds: [SoundCue] = []
  }

  /// - transcribeDelay: how long turning speech into text takes.
  /// - withMonitor: give the controls a shortcut monitor (not started), to see what they ask of it.
  init(
    hasKey: Bool = true,
    captureFailure: WisperError? = nil,
    revealDelay: Duration = .zero,
    noticeTime: Duration = .seconds(60),
    transcribeDelay: Duration = .zero,
    withMonitor: Bool = false
  ) async {
    capture = FakeAudioCapture(failure: captureFailure)
    model = AppModel(
      AppModel.Dependencies(
        library: library,
        secrets: InMemorySecretStore(apiKey: hasKey ? "sk-test" : nil),
        capture: capture,
        transcriber: FakeTranscriber(reply: { _ in
          try? await Task.sleep(for: transcribeDelay)
          return Transcript(text: "Hello there.")
        }),
        languageModel: FakeLanguageModel(text: "Hello there."),
        target: target,
        permissions: FakePermissions(statuses: [.microphone: .granted, .accessibility: .granted]),
        checkAPIKey: { _ in }
      )
    )
    await model.load()
    monitor = withMonitor ? ShortcutMonitor() : nil
    controls = MacControls(model: model, monitor: monitor, revealDelay: revealDelay, noticeTime: noticeTime) {
      [heard] cue in heard.sounds.append(cue)
    }
    controls.open = { [opened] in opened.destinations.append($0) }
  }

  /// Feeds shortcut events in order, as the monitor would in one go.
  func press(_ events: ShortcutEvent...) {
    for event in events { controls.handle(event) }
  }

  var phase: DictationEngine.Phase { model.dictation.phase }

  var isHandsFree: Bool {
    if case .recording(_, _, true) = phase { return true }
    return false
  }

  var isWriting: Bool {
    if case .processing = phase { return true }
    return false
  }

  /// How many times a sound was played.
  func count(_ cue: SoundCue) -> Int { heard.sounds.filter { $0 == cue }.count }

  var recordingMode: DictationMode? {
    if case .recording(let mode, _, _) = phase { return mode }
    return nil
  }

  /// Waits until the dictation is over and returns what was typed.
  func typed() async -> [String] {
    await settle { model.dictation.phase == .idle && !controls.isWrappingUp }
    return await target.inserted
  }
}

/// Waits for `condition`, for at most two seconds.
@MainActor
func settle(_ condition: @MainActor () -> Bool) async {
  for _ in 0..<400 where !condition() {
    try? await Task.sleep(for: .milliseconds(5))
  }
}
