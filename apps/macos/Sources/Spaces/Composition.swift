import AppKit
import SpacesAI
import SpacesAudio
import SpacesDomain
import SpacesEngine
import SpacesMac
import SpacesMacUI
import SpacesStore

/// The one place where the real adapters are put together.
@MainActor
enum Composition {
  /// The objects the app runs on.
  struct Parts {
    var model: AppModel
    var controls: MacControls
    /// Looks for new versions. `nil` in the demo, and in a build that does not update itself.
    var updater: AppUpdater?
  }

  /// The real app: files on disk, the microphone, OpenAI and the global shortcuts.
  static func real() -> Parts {
    let root = SpacesPaths.defaultRoot()
    let library = FileLibrary(root: root)
    // A private file, not the Keychain: the Keychain asked for a yes every time dictation started.
    let secrets = FileSecretStore(file: root.appendingPathComponent(FileSecretStore.fileName))
    let openAI = OpenAI(
      secrets: secrets,
      // Read on every request, so a change in Settings takes effect at once. The address goes
      // through as typed: an unusable one is an error, never a quiet switch to OpenAI.
      address: { try await library.settings().apiBaseURL }
    )
    let monitor = ShortcutMonitor()
    let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/spaces").path
    let target = MacTextTarget()
    let updater = AppUpdater()
    var checkForUpdates: (@MainActor @Sendable () -> Void)?
    if let updater { checkForUpdates = { updater.checkNow() } }
    // The controls are made from the model, and two of the model's parts report to the controls.
    let late = Late()
    let model = AppModel(
      AppModel.Dependencies(
        library: library,
        secrets: secrets,
        capture: SystemAudioCapture(),
        transcriber: openAI.transcriber,
        // Used only when the transcription model in Settings is a live one; otherwise the file is uploaded.
        liveTranscriber: openAI.liveTranscriber,
        languageModel: openAI.languageModel,
        target: target,
        permissions: MacPermissions(),
        host: HostActions(
          agentToolPath: tool,
          dataFolder: root,
          // macOS can refuse, or wait for a yes in System Settings: the controls put the
          // setting right and say so.
          setLaunchAtLogin: { wanted in
            late.controls?.noteLaunchAtLogin(LaunchAtLogin.set(wanted), wanted: wanted)
          },
          reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
          // `shortcutsChanged` is not needed: the controls watch the settings themselves,
          // which also catches a change made by an agent.
          checkForUpdates: checkForUpdates
        ),
        checkAPIKey: { try await openAI.check(key: $0) }
      )
    )
    let controls = MacControls(
      model: model,
      monitor: monitor,
      sounds: SoundPlayer(),
      // The Mac's own fn-key setting, which the app may change when the person asks it to.
      globeKey: GlobeKeySetting(system: .live, memory: .standard),
      pillSpots: PillSpots(defaults: .standard)
    )
    late.controls = controls
    target.onCopied = { [weak controls] in controls?.noteCopied() }
    return Parts(model: model, controls: controls, updater: updater)
  }

  /// Holds the controls for the parts that are made before them.
  @MainActor
  private final class Late {
    weak var controls: MacControls?
  }

  /// The whole app on made-up data, for trying it out and for screenshots.
  /// No shortcuts, no sounds and no updates: nothing it does can be noticed outside its own windows.
  /// - firstRun: start before setup. A pretend key is already saved, so every step can be clicked through.
  static func demo(firstRun: Bool) -> Parts {
    let model = AppModel.demo(onboarded: !firstRun)
    return Parts(model: model, controls: MacControls(model: model))
  }
}

/// Makes sure only one Spaces runs.
@MainActor
enum OtherInstance {
  private static let wake = Notification.Name("dev.openspaces.mac.show-hub")

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
