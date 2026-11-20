import Foundation
import SpacesDomain

/// Where the app and its keyboard keep the library, so both read the same files.
///
/// iOS gives an app and its extensions one folder in common: the App Group container. It
/// exists only in a build signed with the App Group. In any other build (a simulator build
/// made without signing, for one) each side has a folder of its own, and `isShared`
/// says so.
public struct SharedFolder: Sendable {
  /// The App Group the app and the keyboard both belong to.
  public static let groupID = "group.dev.openspaces"

  /// The folder that holds the library.
  public let root: URL
  /// Whether the app and the keyboard see the same `root`.
  public let isShared: Bool

  /// Finds the folder for this process.
  ///
  /// `SPACES_HOME` wins when it is set, as everywhere else in Spaces.
  public init() {
    let override = ProcessInfo.processInfo.environment[SpacesPaths.homeVariable] ?? ""
    if override.isEmpty, let container = SharedFolder.groupContainer() {
      root = container.appendingPathComponent("Spaces", isDirectory: true)
      isShared = true
    } else {
      root = SpacesPaths.defaultRoot()
      isShared = false
    }
  }

  /// The App Group's container as iOS reports it, or `nil` when this build may not use it.
  /// Always `nil` off iOS, where this package is only built for its snapshots.
  private static func groupContainer() -> URL? {
    #if os(iOS)
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    #else
      nil
    #endif
  }
}
