import Foundation
import Testing
import WisperDomain
import WisperEngine

@testable import WisperPhone

/// Collects what was put on the clipboard.
@MainActor
final class Copied {
  private(set) var texts: [String] = []
  var last: String? { texts.last }

  var clipboard: Clipboard {
    Clipboard { [weak self] text in self?.texts.append(text) }
  }
}

/// Collects what was shown on the Lock Screen: a meeting's title, or `nil` for "taken away".
@MainActor
final class LockScreen {
  var titles: [String?] = []
}

/// Permissions whose answer to the system question is set by the test.
@MainActor
final class ScriptedPermissions: Permissions {
  let needed: [Permission] = [.microphone]
  var microphone: PermissionStatus
  /// What the person answers when asked.
  var answer: PermissionStatus
  private(set) var requests = 0

  init(microphone: PermissionStatus, answer: PermissionStatus = .granted) {
    self.microphone = microphone
    self.answer = answer
  }

  func status(_ permission: Permission) -> PermissionStatus {
    permission == .microphone ? microphone : .granted
  }

  func request(_ permission: Permission) async -> PermissionStatus {
    requests += 1
    if microphone == .notDetermined { microphone = answer }
    return microphone
  }
}

/// A transcriber that fails until told to work.
final class FlakyTranscriber: Transcriber, @unchecked Sendable {
  private let lock = NSLock()
  private var failing = true
  let text: String

  init(text: String = "Call the dentist tomorrow morning.") {
    self.text = text
  }

  func heal() { lock.withLock { failing = false } }

  func transcribe(_ request: TranscriptionRequest) async throws -> Transcript {
    if lock.withLock({ failing }) { throw WisperError.network("offline") }
    return Transcript(text: text)
  }
}

/// A phone app on fakes: nothing is recorded, sent or stored outside memory.
@MainActor
struct Rig {
  let library: InMemoryLibrary
  let capture: FakeAudioCapture
  let permissions: ScriptedPermissions
  let copied = Copied()
  let lockScreen = LockScreen()
  let model: AppModel
  let session: PhoneSession
  /// Stands in for the folder the app shares with its keyboard. Tickets are left here.
  let folder = FileManager.default.temporaryDirectory
    .appendingPathComponent("wisper-phone-tests-\(UUID().uuidString)", isDirectory: true)

  var dictation: PhoneDictation { session.dictation }

  init(
    key: String? = "sk-test",
    microphone: PermissionStatus = .granted,
    answer: PermissionStatus = .granted,
    settings: Settings = Settings(onboardedAt: Date()),
    snippets: [Snippet] = [],
    dictations: [Dictation] = [],
    transcriber: any Transcriber = FakeTranscriber(text: "Call the dentist tomorrow morning."),
    capture: FakeAudioCapture = FakeAudioCapture()
  ) async {
    self.capture = capture
    library = InMemoryLibrary(settings: settings, snippets: snippets, dictations: dictations)
    permissions = ScriptedPermissions(microphone: microphone, answer: answer)
    let clipboard = copied.clipboard
    model = AppModel(
      AppModel.Dependencies(
        library: library,
        secrets: InMemorySecretStore(apiKey: key),
        capture: capture,
        transcriber: transcriber,
        // Hands back what it was given, as a model that finds nothing to tidy would.
        languageModel: FakeLanguageModel { request in request.user },
        target: ClipboardTextTarget(clipboard: clipboard),
        permissions: permissions,
        checkAPIKey: { _ in }
      )
    )
    let notices = lockScreen
    let folder = folder
    session = PhoneSession(
      model: model,
      device: PhoneDevice(
        clipboard: clipboard,
        keepAwake: { _ in },
        openSettings: {},
        keyboardIsOn: { nil },
        showRecording: { recording in notices.titles.append(recording?.title) },
        redeemTicket: { ticket in LinkTicket.redeem(ticket, in: folder) }
      )
    )
    await session.start()
  }
}

extension Rig {
  /// A link as the Open Wisper keyboard sends it: with a fresh ticket.
  func ticketed(_ link: WisperLink) throws -> URL {
    link.url(ticket: try LinkTicket.issue(in: folder))
  }
}

/// Waits until `condition` holds, for things that arrive through a stream.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
  for _ in 0..<400 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}
