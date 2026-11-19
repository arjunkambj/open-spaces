import Foundation
import Testing

@testable import WisperMac

@Suite struct UpdateReadinessTests {
  private let app = "/Applications/Open Wisper.app"

  /// What a finished app has in its Info.plist.
  private func info(_ changes: [String: Any?] = [:]) -> [String: Any] {
    var info: [String: Any] = [
      "CFBundleIdentifier": "dev.openwisper.mac",
      "CFBundleShortVersionString": "0.1.0",
      "CFBundleVersion": "100.33",
      "SUFeedURL": "https://github.com/arjunkambj/open-wisper/releases/latest/download/appcast.xml",
      "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
    ]
    for (key, value) in changes { info[key] = value }
    return info
  }

  @Test func aFinishedAppCanUpdateItself() {
    #expect(UpdateReadiness.problem(bundlePath: app, info: info()) == nil)
    #expect(UpdateReadiness.problem(bundlePath: "/Users/me/Apps/Open Wisper.APP", info: info()) == nil)
  }

  @Test func aProgramInABuildFolderCannot() {
    // `swift run` and the tests start the program with no app around it.
    let problem = UpdateReadiness.problem(bundlePath: "/work/apps/macos/.build/debug", info: [:])
    #expect(problem == "It is not running from an app bundle.")
    #expect(UpdateReadiness.problem(bundlePath: "/work/.build/debug", info: info()) != nil)
    #expect(UpdateReadiness.problem(bundlePath: "", info: info()) != nil)
  }

  @Test func anAppWithNoIdentifierCannot() {
    #expect(UpdateReadiness.problem(bundlePath: app, info: info(["CFBundleIdentifier": nil])) != nil)
    #expect(UpdateReadiness.problem(bundlePath: app, info: info(["CFBundleIdentifier": ""])) != nil)
  }

  @Test func theBuildNumberMustHaveBeenFilledIn() {
    // Info.plist in the repository says 0; the bundle script puts the real number in.
    let wrong = [
      "0", "000", "0.33", "", "12b", "100.33-beta", "-3", " 4", "٣٣", "1..2", ".1", "1.", "1.2.3.4",
      "1234567890",
    ]
    for build in wrong {
      let problem = UpdateReadiness.problem(bundlePath: app, info: info(["CFBundleVersion": build]))
      #expect(problem == "The app has no build number.", "\(build)")
      #expect(!UpdateReadiness.isBuildNumber(build), "\(build)")
    }
    #expect(UpdateReadiness.problem(bundlePath: app, info: info(["CFBundleVersion": nil])) != nil)
    for build in ["1", "33", "007", "100.33", "10203.57", "1.0.0", "999999999"] {
      #expect(UpdateReadiness.isBuildNumber(build), "\(build)")
    }
  }

  @Test func theAddressForUpdatesMustBeSecure() {
    for address in [
      "http://example.com/appcast.xml", "appcast.xml", "", "https://", "file:///tmp/appcast.xml",
    ] {
      let problem = UpdateReadiness.problem(bundlePath: app, info: info(["SUFeedURL": address]))
      #expect(problem == "The app has no secure address to ask for updates.", "\(address)")
    }
    #expect(UpdateReadiness.problem(bundlePath: app, info: info(["SUFeedURL": nil])) != nil)
  }

  @Test func theKeyMustBeAWholeKey() {
    let short = Data(repeating: 7, count: 31).base64EncodedString()
    for key in ["", "not base64!", short] {
      let problem = UpdateReadiness.problem(bundlePath: app, info: info(["SUPublicEDKey": key]))
      #expect(problem == "The app has no key to check updates with.", "\(key)")
    }
    #expect(UpdateReadiness.problem(bundlePath: app, info: info(["SUPublicEDKey": nil])) != nil)
  }

  /// The Info.plist in the repository, as the bundle script leaves it once the version is filled in.
  @Test func theAppsOwnInfoPlistIsReadyOnceTheBuildNumberIsFilledIn() throws {
    let plist = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Info.plist")
    let read = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
    var info = try #require(read as? [String: Any])
    #expect(UpdateReadiness.problem(bundlePath: app, info: info) == "The app has no build number.")
    info["CFBundleVersion"] = "100.33"
    #expect(UpdateReadiness.problem(bundlePath: app, info: info) == nil)
    // Checked about once a day, without sending anything about the Mac.
    #expect(info["SUScheduledCheckInterval"] as? Int == 86_400)
    #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
    #expect(info["SUEnableSystemProfiling"] as? Bool == false)
    // A download is checked before it is opened, and so is the list of versions.
    #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    #expect(info["SURequireSignedFeed"] as? Bool == true)
  }
}
