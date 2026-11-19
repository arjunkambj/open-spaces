import Foundation
import Testing

/// Checks on the built app, run inside it: the things `project.yml` promises.
@Suite struct BundleTests {
  private let info = Bundle.main.infoDictionary ?? [:]

  @Test func isTheApp() {
    #expect(Bundle.main.bundleIdentifier == "dev.openwisper.ios")
    #expect(info["CFBundleDisplayName"] as? String == "Open Wisper")
  }

  @Test func saysWhyItWantsTheMicrophone() {
    let reason = info["NSMicrophoneUsageDescription"] as? String ?? ""
    #expect(reason.count > 20)
  }

  @Test func keepsRecordingInTheBackground() {
    let modes = info["UIBackgroundModes"] as? [String] ?? []
    #expect(modes.contains("audio"))
  }

  @Test func answersOpenWisperLinks() {
    let types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
    let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    #expect(schemes == ["openwisper"])
  }

  @Test func carriesTheKeyboard() throws {
    let plugins = try #require(Bundle.main.builtInPlugInsURL)
    let keyboard = try #require(Bundle(url: plugins.appendingPathComponent("OpenWisperKeyboard.appex")))
    #expect(keyboard.bundleIdentifier == "dev.openwisper.ios.keyboard")
    let point = (keyboard.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"]
    #expect(point as? String == "com.apple.keyboard-service")
  }

  @Test func carriesTheLockScreenNotice() throws {
    #expect(info["NSSupportsLiveActivities"] as? Bool == true)
    let plugins = try #require(Bundle.main.builtInPlugInsURL)
    let widgets = try #require(Bundle(url: plugins.appendingPathComponent("OpenWisperWidgets.appex")))
    #expect(widgets.bundleIdentifier == "dev.openwisper.ios.widgets")
    let point = (widgets.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"]
    #expect(point as? String == "com.apple.widgetkit-extension")
  }

  /// The Stop button on the Lock Screen is an App Intent. iOS only runs it when both the
  /// widget that shows it and the app that performs it list it in their built metadata.
  @Test func theStopButtonIsKnownToTheAppAndToTheWidget() throws {
    let plugins = try #require(Bundle.main.builtInPlugInsURL)
    let widgets = plugins.appendingPathComponent("OpenWisperWidgets.appex")
    for bundle in [Bundle.main.bundleURL, widgets] {
      let actions = try Self.actions(in: bundle)
      #expect(actions.contains("StopRecordingIntent"), "\(bundle.lastPathComponent)")
    }
  }

  /// Shortcuts and Siri find the app's actions in the same metadata.
  @Test func offersItsActionsToShortcuts() throws {
    let actions = try Self.actions(in: Bundle.main.bundleURL)
    for name in [
      "StartDictationIntent", "StartMeetingIntent", "StopMeetingIntent", "CopyLastDictationIntent",
    ] {
      #expect(actions.contains(name), "\(name)")
    }
  }

  /// Everything Xcode wrote about a bundle's App Intents, as one text.
  private static func actions(in bundle: URL) throws -> String {
    let folder = bundle.appendingPathComponent("Metadata.appintents", isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    return files.compactMap { try? Data(contentsOf: $0) }
      .map { String(decoding: $0, as: UTF8.self) }
      .joined()
  }

  @Test func hasALaunchScreenAndAnIcon() {
    let launch = info["UILaunchScreen"] as? [String: Any] ?? [:]
    #expect(launch["UIColorName"] as? String == "LaunchBackground")
    #expect(launch["UIImageName"] as? String == "LaunchGlyph")
    let icons = info["CFBundleIcons"] as? [String: Any]
    #expect(icons != nil)
  }
}
