import SpacesEngine
import SwiftUI

/// One screen state to render to an image, so a screen can be looked at
/// without running the app.
///
/// Each area lists its cases in `Screens/<Area>/<Area>Snapshots.swift`.
/// The renderer puts a loaded demo `AppModel` in the environment.
public struct SnapshotCase {
  public enum Canvas: Sendable, Equatable {
    /// The content area of the macOS hub window.
    case mac
    case custom(width: CGFloat, height: CGFloat)

    public var size: CGSize {
      switch self {
      case .mac: CGSize(width: 880, height: 720)
      case .custom(let width, let height): CGSize(width: width, height: height)
      }
    }
  }

  /// File name without extension, e.g. `home-empty`.
  public var name: String
  public var canvas: Canvas
  public var view: AnyView
  /// Makes the app model for this case. The renderer calls `load()` on it.
  public var model: @MainActor () -> AppModel

  /// - model: a different starting state, e.g. `{ .demo(onboarded: false) }`. Leave out for the standard demo.
  @MainActor
  public init<Content: View>(
    _ name: String,
    canvas: Canvas = .mac,
    model: @escaping @MainActor () -> AppModel = { .demo() },
    @ViewBuilder view: () -> Content
  ) {
    self.name = name
    self.canvas = canvas
    self.model = model
    self.view = AnyView(view())
  }
}

/// Every snapshot case in this package.
public enum SnapshotRegistry {
  @MainActor public static var all: [SnapshotCase] {
    DesignSnapshots.cases + HomeSnapshots.cases + TasksSnapshots.cases + DictionarySnapshots.cases
      + SnippetsSnapshots.cases
      + StyleSnapshots.cases + MeetingsSnapshots.cases + SettingsSnapshots.cases + OnboardingSnapshots.cases
  }
}
