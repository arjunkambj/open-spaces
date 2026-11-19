import AVFoundation
import ApplicationServices
import Foundation
import Testing
import WisperDomain

@testable import WisperMac

/// Only reads statuses. Nothing here asks the system for a permission.
@MainActor
@Suite struct MacPermissionsTests {
  private let suite = "dev.openwisper.tests.\(UUID().uuidString)"

  private func permissions(systemAudio: PermissionStatus?) -> (MacPermissions, UserDefaults) {
    let defaults = UserDefaults(suiteName: suite)!
    let access = SystemAudioAccess(status: { systemAudio }, request: { nil })
    return (MacPermissions(defaults: defaults, systemAudio: access), defaults)
  }

  private func cleanUp(_ defaults: UserDefaults) { defaults.removePersistentDomain(forName: suite) }

  @Test func asksInTheOrderTheAppNeedsThem() {
    let (permissions, defaults) = permissions(systemAudio: nil)
    defer { cleanUp(defaults) }
    #expect(permissions.needed == [.microphone, .accessibility, .systemAudio])
  }

  @Test func systemAudioUsesTheSystemsAnswerWhenThereIsOne() {
    for status in [PermissionStatus.granted, .denied, .notDetermined] {
      let (permissions, defaults) = permissions(systemAudio: status)
      defer { cleanUp(defaults) }
      #expect(permissions.status(.systemAudio) == status)
    }
  }

  @Test func systemAudioFallsBackToTheLastAnswerTheSystemGave() {
    let (unknown, defaults) = permissions(systemAudio: nil)
    defer { cleanUp(defaults) }
    #expect(unknown.status(.systemAudio) == .notDetermined, "Never asked, and no way to ask")
    // On a macOS where the system can be asked, its answer is remembered...
    #expect(permissions(systemAudio: .granted).0.status(.systemAudio) == .granted)
    // ...and stands in on a macOS where it cannot.
    #expect(unknown.status(.systemAudio) == .granted)
    #expect(permissions(systemAudio: .denied).0.status(.systemAudio) == .denied)
    #expect(unknown.status(.systemAudio) == .denied)
  }

  @Test func thePrivateCheckIsOnlyUsedOnKnownVersionsOfMacOS() async {
    #expect(
      SystemAudioAccess.knownVersions.contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    )
    // A macOS that did not exist when this was written: nothing private is called.
    let later = SystemAudioAccess.forMacOS(major: (SystemAudioAccess.knownVersions.max() ?? 0) + 1)
    #expect(later.status() == nil)
    #expect(await later.request() == nil)
    #expect(SystemAudioAccess.forMacOS(major: 13).status() == nil)
  }

  @Test func accessibilityIsNotDeterminedUntilAsked() {
    let (permissions, defaults) = permissions(systemAudio: nil)
    defer { cleanUp(defaults) }
    let expected: PermissionStatus = AXIsProcessTrusted() ? .granted : .notDetermined
    #expect(permissions.status(.accessibility) == expected)
  }

  @Test func microphoneStatusMatchesTheSystem() {
    let (permissions, defaults) = permissions(systemAudio: nil)
    defer { cleanUp(defaults) }
    let expected: PermissionStatus =
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized: .granted
      case .notDetermined: .notDetermined
      default: .denied
      }
    #expect(permissions.status(.microphone) == expected)
  }

  @Test func theRealSystemAudioCheckAnswersWithoutAsking() {
    // Whatever it says, it must say it without a prompt and without crashing.
    let status = SystemAudioAccess.system.status()
    #expect(status == nil || [.granted, .denied, .notDetermined].contains(status))
  }

  @Test(arguments: [
    (Permission.microphone, "Privacy_Microphone"),
    (.accessibility, "Privacy_Accessibility"),
    (.systemAudio, "Privacy_AudioCapture"),
  ])
  func settingsLinksPointAtTheRightPane(permission: Permission, anchor: String) {
    let urls = MacPermissions.settingsURLs(for: permission)
    #expect(urls.count == 2)
    for url in urls {
      #expect(url.scheme == "x-apple.systempreferences")
      #expect(url.absoluteString.hasSuffix("?\(anchor)"))
    }
    #expect(urls.first?.absoluteString.contains("com.apple.settings.PrivacySecurity.extension") == true)
  }
}

@Suite struct ToneTests {
  @Test(arguments: SoundCue.allCases) func soundsAreShortAndSoft(cue: SoundCue) {
    let samples = Tone.samples(for: cue)
    let seconds = Double(samples.count) / Tone.sampleRate
    #expect(seconds > 0.1 && seconds < 0.5)
    let peak = samples.map(abs).max() ?? 0
    #expect(peak > 0.05, "not silent")
    #expect(peak < 0.5, "not loud")
    // No click at either end.
    #expect(abs(samples.first ?? 1) < 0.01)
    #expect(abs(samples.last ?? 1) < 0.01)
  }

  @Test func theThreeSoundsDiffer() {
    #expect(Tone.samples(for: .start) != Tone.samples(for: .stop))
    #expect(Tone.samples(for: .start) != Tone.samples(for: .error))
  }

  @Test(arguments: SoundCue.allCases) func soundsAreValidAudioFiles(cue: SoundCue) throws {
    let data = Tone.wav(for: cue)
    #expect(data.prefix(4) == Data("RIFF".utf8))
    #expect(data.count == 44 + Tone.samples(for: cue).count * 2)
    // Decoding only: nothing is played.
    let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
    #expect(abs(player.duration - Double(Tone.samples(for: cue).count) / Tone.sampleRate) < 0.01)
    #expect(player.numberOfChannels == 1)
  }
}

@Suite struct GlobeKeyTests {
  @Test func readsTheSystemSetting() {
    #expect(GlobeKey.systemUse(setting: 0) == .nothing)
    #expect(GlobeKey.systemUse(setting: 1) == .changeInputSource)
    #expect(GlobeKey.systemUse(setting: 2) == .showEmoji)
    #expect(GlobeKey.systemUse(setting: 3) == .startDictation)
    #expect(GlobeKey.systemUse(setting: nil) == .systemDefault)
    #expect(GlobeKey.systemUse(setting: "nonsense") == .systemDefault)
  }

  @Test func readingTheRealSettingDoesNotCrash() {
    _ = GlobeKey.systemUse
    _ = GlobeKey.interferes
  }
}

@MainActor
@Suite struct LaunchAtLoginTests {
  @Test func isUnavailableOutsideAnAppBundle() {
    // The test runner is not "Open Wisper.app", so nothing may be registered.
    #expect(LaunchAtLogin.status == .unavailable)
    #expect(LaunchAtLogin.set(true) == .unavailable)
  }
}

/// The files `scripts/bundle` builds the app from.
@Suite struct BundleResourceTests {
  private static let package = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func plist(_ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: Self.package.appendingPathComponent("Resources/\(name)"))
    let value = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(value as? [String: Any])
  }

  @Test func infoPlistDescribesTheApp() throws {
    let info = try plist("Info.plist")
    #expect(info["CFBundleIdentifier"] as? String == "dev.openwisper.mac")
    #expect(info["CFBundleName"] as? String == "Open Wisper")
    #expect(info["CFBundleExecutable"] as? String == "OpenWisper")
    #expect(info["CFBundlePackageType"] as? String == "APPL")
    #expect(info["CFBundleIconFile"] as? String == "AppIcon")
    #expect(info["LSMinimumSystemVersion"] as? String == "14.4")
    #expect(info["LSApplicationCategoryType"] as? String == "public.app-category.productivity")
    #expect(info["NSHighResolutionCapable"] as? Bool == true)
    #expect(info["LSUIElement"] as? Bool == true)
    #expect(info["CFBundleShortVersionString"] is String)
    #expect(info["CFBundleVersion"] is String)
  }

  @Test func everyPermissionTheAppAsksForIsExplained() throws {
    let info = try plist("Info.plist")
    for key in ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription"] {
      let text = try #require(info[key] as? String, "\(key)")
      #expect(text.count > 30)
      #expect(text.contains("Open Wisper"))
    }
    // The app drives other apps with key presses, never with Apple events.
    #expect(info["NSAppleEventsUsageDescription"] == nil)
  }

  @Test func theAppAnswersToItsLinks() throws {
    let info = try plist("Info.plist")
    let types = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
    let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    #expect(schemes == [WisperLink.scheme])
  }

  @Test func entitlementsAskOnlyForTheMicrophone() throws {
    let entitlements = try plist("OpenWisper.entitlements")
    #expect(entitlements.keys.sorted() == ["com.apple.security.device.audio-input"])
    #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
  }
}
