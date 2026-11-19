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

  @MainActor
  final class Opened {
    var destinations: [MacControls.Destination] = []
  }

  init(
    hasKey: Bool = true,
    captureFailure: WisperError? = nil,
    revealDelay: Duration = .zero,
    noticeTime: Duration = .seconds(60)
  ) async {
    capture = FakeAudioCapture(failure: captureFailure)
    model = AppModel(
      AppModel.Dependencies(
        library: library,
        secrets: InMemorySecretStore(apiKey: hasKey ? "sk-test" : nil),
        capture: capture,
        transcriber: FakeTranscriber(text: "Hello there."),
        languageModel: FakeLanguageModel(text: "Hello there."),
        target: target,
        permissions: FakePermissions(statuses: [.microphone: .granted, .accessibility: .granted]),
        checkAPIKey: { _ in }
      )
    )
    await model.load()
    controls = MacControls(model: model, revealDelay: revealDelay, noticeTime: noticeTime)
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
