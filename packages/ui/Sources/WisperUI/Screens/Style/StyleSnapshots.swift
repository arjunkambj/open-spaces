import SwiftUI
import WisperDomain
import WisperEngine

/// Snapshot cases for this area. See `SnapshotCase`.
enum StyleSnapshots {
  @MainActor static var cases: [SnapshotCase] {
    [
      SnapshotCase("style") { StyleScreen() },
      SnapshotCase("style-phone", canvas: .phone) { StyleScreen() },
      SnapshotCase("style-work") { StyleScreen(category: .workMessages) },
      SnapshotCase("style-work-phone", canvas: .phone) { StyleScreen(category: .workMessages) },
      SnapshotCase("style-email") { StyleScreen(category: .email) },
      SnapshotCase("style-email-phone", canvas: .phone) { StyleScreen(category: .email) },
      SnapshotCase("style-other") { StyleScreen(category: .other) },
      SnapshotCase("style-narrow", canvas: .custom(width: 640, height: 720)) {
        StyleScreen().background(Wisper.Color.panel)
      },
      SnapshotCase("style-off", model: { plainModel }) { StyleScreen(category: .email) },
      SnapshotCase("style-off-phone", canvas: .phone, model: { plainModel }) {
        StyleScreen(category: .email)
      },
    ]
  }

  /// Smart formatting turned off, and no name.
  @MainActor private static var plainModel: WisperEngine.AppModel {
    ScreenSamples.model(settings: .init(userName: "", onboardedAt: Date(), smartFormatting: false))
  }
}
