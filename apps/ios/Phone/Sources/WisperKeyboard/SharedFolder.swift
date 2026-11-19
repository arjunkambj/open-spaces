import Foundation
import WisperDomain

/// Where the app and its keyboard keep the library, so both read the same files.
///
/// iOS gives an app and its extensions one folder in common: the App Group container. It
/// exists only in a build signed with the App Group. In any other build (a simulator build
/// made without signing, for one) each side falls back to a folder of its own, and
/// `isShared` says so.
public struct SharedFolder: Sendable, Equatable {
  /// The App Group the app and the keyboard both belong to.
  public static let groupID = "group.dev.openwisper"

  /// The folder that holds the library.
  public let root: URL
  /// Whether the app and the keyboard see the same `root`.
  public let isShared: Bool

  /// Finds the folder for this process.
  ///
  /// `OPEN_WISPER_HOME` wins when it is set, as everywhere else in Open Wisper.
  /// - Parameters:
  ///   - groupContainer: returns the container of an App Group, or `nil` when this build
  ///     may not use it.
  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    groupContainer: (String) -> URL? = SharedFolder.systemContainer
  ) {
    let override = environment[WisperPaths.homeVariable] ?? ""
    if override.isEmpty, let container = groupContainer(SharedFolder.groupID) {
      root = container.appendingPathComponent(SharedFolder.folderName, isDirectory: true)
      isShared = true
    } else {
      root = WisperPaths.defaultRoot(environment: environment)
      isShared = false
    }
  }

  /// Moves a library from the app's own folder into the shared one. For the app to call
  /// once at launch: a person who first ran a build without the App Group keeps their data
  /// when they later sign the app properly. Does nothing when there is nothing to move or
  /// the shared folder already holds a library.
  /// - Parameter privateRoot: where a build without the App Group keeps the library.
  public func adoptLibrary(from privateRoot: URL = WisperPaths.defaultRoot(environment: [:])) {
    let files = FileManager.default
    guard isShared, privateRoot.standardizedFileURL != root.standardizedFileURL,
      files.fileExists(atPath: privateRoot.path), !files.fileExists(atPath: root.path)
    else { return }
    try? files.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? files.moveItem(at: privateRoot, to: root)
  }

  /// The App Group's container as iOS reports it. Always `nil` off iOS, where this
  /// package is only built for its tests and snapshots.
  public static func systemContainer(_ group: String) -> URL? {
    #if os(iOS)
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    #else
      nil
    #endif
  }

  private static let folderName = "Open Wisper"
}
