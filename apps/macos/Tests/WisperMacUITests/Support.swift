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
  /// - host: what the app offers the shared screens, such as a check for updates.
  /// - globeKey: the fn-key setting the controls see; the default reads "Do Nothing".
  /// - pillSpots: where the pill was dragged to; the default remembers nothing.
  init(
    host: HostActions = HostActions(),
    hasKey: Bool = true,
    captureFailure: WisperError? = nil,
    revealDelay: Duration = .zero,
    noticeTime: Duration = .seconds(60),
    transcribeDelay: Duration = .zero,
    withMonitor: Bool = false,
    globeKey: GlobeKeySetting? = nil,
    pillSpots: PillSpots? = nil
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
        host: host,
        checkAPIKey: { _ in }
      )
    )
    await model.load()
    monitor = withMonitor ? ShortcutMonitor() : nil
    controls = MacControls(
      model: model,
      monitor: monitor,
      revealDelay: revealDelay,
      noticeTime: noticeTime,
      globeKey: globeKey,
      pillSpots: pillSpots
    ) {
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

/// Stands in for the Mac's fn (Globe) key setting. Nothing on the Mac is read or changed.
final class FakeGlobeSystem: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Int?
  private var written: [Int] = []
  private let outcome: GlobeKey.Outcome

  /// - value: what "Press 🌐 key to" is set to (0 to 3), or `nil` for never chosen.
  /// - outcome: how a change goes. A failed one leaves the value as it was.
  init(value: Int?, outcome: GlobeKey.Outcome = .now) {
    stored = value
    self.outcome = outcome
  }

  /// Every value that was written, in order.
  var writes: [Int] { lock.withLock { written } }

  var value: Int? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }

  var system: GlobeKey.System {
    GlobeKey.System(
      read: { self.value },
      write: { value in
        self.lock.withLock {
          self.written.append(value)
          if self.outcome != .failed { self.stored = value }
        }
        return self.outcome
      }
    )
  }
}
