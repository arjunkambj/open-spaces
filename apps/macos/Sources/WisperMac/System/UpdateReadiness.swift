import Foundation

/// Whether this copy of the app is one that can update itself.
///
/// Only a finished "Open Wisper.app" can: it has a version to compare, an address to ask
/// for new versions, and the key that proves a download came from the people who make the
/// app. A bare program in a build folder has none of these, and must not look for updates.
public enum UpdateReadiness {
  /// The first reason this copy of the app cannot update itself, or `nil` when it can.
  /// - Parameters:
  ///   - bundlePath: where the app is, such as `Bundle.main.bundlePath`.
  ///   - info: the app's Info.plist, such as `Bundle.main.infoDictionary`.
  public static func problem(bundlePath: String, info: [String: Any]) -> String? {
    guard (bundlePath as NSString).pathExtension.lowercased() == "app" else {
      return "It is not running from an app bundle."
    }
    guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
      return "The app has no identifier."
    }
    // The build script fills in the build number. Updates are compared by it, so it must be
    // real, and not the placeholder 0.
    guard let build = info["CFBundleVersion"] as? String, isBuildNumber(build) else {
      return "The app has no build number."
    }
    guard let address = info["SUFeedURL"] as? String, let feed = URL(string: address),
      feed.scheme?.lowercased() == "https", feed.host?.isEmpty == false
    else {
      return "The app has no secure address to ask for updates."
    }
    guard let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else {
      return "The app has no key to check updates with."
    }
    return nil
  }

  /// A build number is one to three whole numbers with dots between them, the first above
  /// zero: `100.33` or `33`, but not `0`, `0.33`, `100.33-beta` or `1..2`.
  ///
  /// The build script writes the version as one number first and the count of commits
  /// second (version 0.1.0 at 33 commits is `100.33`), so a newer version always has the
  /// higher build number. An update is offered when its build number is higher than that
  /// of the app that is running.
  public static func isBuildNumber(_ text: String) -> Bool {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return false }
    for part in parts {
      guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        return false
      }
    }
    return Int(parts[0]).map { $0 > 0 } ?? false
  }
}
