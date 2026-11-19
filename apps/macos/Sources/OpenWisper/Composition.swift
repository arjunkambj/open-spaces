import AppKit
import WisperAI
import WisperAudio
import WisperDomain
import WisperEngine
import WisperMac
import WisperMacUI
import WisperStore

/// The one place where the real adapters are put together.
@MainActor
enum Composition {
  /// The objects the app runs on.
  struct Parts {
    var model: AppModel
    var controls: MacControls
  }

  /// The real app: files on disk, the Keychain, the microphone, OpenAI and the global shortcuts.
  static func real() -> Parts {
    let root = WisperPaths.defaultRoot()
    let library = FileLibrary(root: root)
    let secrets = KeychainSecretStore()
    let openAI = OpenAI(
      secrets: secrets,
      baseURL: {
        // Read on every request, so a change in Settings takes effect at once.
        let text = (try? await library.settings().apiBaseURL) ?? nil
        return text.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      }
    )
    let monitor = ShortcutMonitor()
    let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/wisper").path
    let model = AppModel(
      AppModel.Dependencies(
        library: library,
        secrets: secrets,
        capture: SystemAudioCapture(),
        transcriber: openAI.transcriber,
        languageModel: openAI.languageModel,
        target: MacTextTarget(),
        permissions: MacPermissions(),
        host: HostActions(
          agentToolPath: FileManager.default.isExecutableFile(atPath: tool) ? tool : nil,
          dataFolder: root,
          setLaunchAtLogin: { LaunchAtLogin.set($0) },
          reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
          // `shortcutsChanged` is not needed: the controls watch the settings themselves,
          // which also catches a change made by an agent.
        ),
        checkAPIKey: { try await openAI.check(key: $0) }
      )
    )
    return Parts(model: model, controls: MacControls(model: model, monitor: monitor, sounds: SoundPlayer()))
  }

  /// The whole app on made-up data, for trying it out and for screenshots.
  /// No shortcuts and no sounds: nothing it does can be noticed outside its own windows.
  /// - firstRun: start before setup. A pretend key is already saved, so every step can be clicked through.
  static func demo(firstRun: Bool) -> Parts {
    let model = AppModel.demo(onboarded: !firstRun)
    return Parts(model: model, controls: MacControls(model: model))
  }
}

/// Makes sure only one Open Wisper runs.
@MainActor
enum OtherInstance {
  private static let wake = Notification.Name("dev.openwisper.mac.show-hub")

  /// When another copy is already running, asks it to show its window and returns true.
  static func handOver() -> Bool {
    guard let id = Bundle.main.bundleIdentifier else { return false }
    let own = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
      .filter { $0.processIdentifier != own && !$0.isTerminated }
    guard let other = others.first else { return false }
    DistributedNotificationCenter.default().postNotificationName(
      wake,
      object: id,
      userInfo: nil,
      deliverImmediately: true
    )
    other.activate()
    return true
  }

  /// Calls `show` when a second copy was started and handed over to this one.
  static func listen(_ show: @escaping @MainActor () -> Void) {
    guard let id = Bundle.main.bundleIdentifier else { return }
    DistributedNotificationCenter.default().addObserver(forName: wake, object: id, queue: .main) { _ in
      MainActor.assumeIsolated { show() }
    }
  }
}
