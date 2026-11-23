import SpacesDomain
import SpacesEngine
import SwiftUI

/// Snapshot cases for this area. See `SnapshotCase`.
enum OnboardingSnapshots {
  /// The size of the Mac onboarding window.
  private static let window = SnapshotCase.Canvas.custom(width: 720, height: 560)

  @MainActor static var cases: [SnapshotCase] {
    var cases: [SnapshotCase] = []
    for step in OnboardingStep.allCases {
      cases.append(flow("onboarding-\(step.rawValue)", OnboardingPreview(step: step)))
    }
    cases += [
      flow(
        "onboarding-key-error",
        OnboardingPreview(
          step: .key,
          key: "not-a-key",
          keyError: APIKeyEntry.message(for: SpacesError.invalidAPIKey)
        )
      ),
      flow("onboarding-key-checking", OnboardingPreview(step: .key, key: "sk-demo-key", isChecking: true)),
      flow("onboarding-key-saved", OnboardingPreview(step: .key), hasAPIKey: true),
      flow("onboarding-key-server", OnboardingPreview(step: .key, server: "http://localhost:11434/v1")),
      flow(
        "onboarding-key-server-not-private",
        OnboardingPreview(step: .key, server: "http://models.example.com/v1")
      ),
      flow(
        "onboarding-permissions-allowed",
        OnboardingPreview(step: .permissions),
        permissions: [.microphone: .granted, .accessibility: .granted, .systemAudio: .granted]
      ),
      flow(
        "onboarding-permissions-denied",
        OnboardingPreview(step: .permissions),
        permissions: [.microphone: .granted, .accessibility: .denied]
      ),
    ]
    return cases
  }

  @MainActor private static func flow(
    _ name: String,
    _ preview: OnboardingPreview,
    hasAPIKey: Bool = false,
    permissions: [Permission: PermissionStatus] = [:]
  ) -> SnapshotCase {
    SnapshotCase(
      name,
      canvas: window,
      model: {
        SetupSnapshotModels.make(
          onboarded: preview.step != .welcome && preview.step != .name,
          hasAPIKey: hasAPIKey,
          permissions: permissions,
          settings: { $0.onboardedAt = nil }
        )
      }
    ) {
      OnboardingFlow(practice: AnyView(PracticeStandIn()), preview: preview)
    }
  }
}

/// Stands in for the practice step the Mac app supplies.
private struct PracticeStandIn: View {
  var body: some View {
    VStack(spacing: Spaces.Space.xl) {
      Text("Try it once")
        .spacesText(.hero)
      Text("The Mac app puts its shortcut step here.")
        .spacesText(.body, color: Spaces.Color.textSecondary)
        .multilineTextAlignment(.center)
      KeyCapRow(["fn"])
    }
    .padding(Spaces.Space.xl)
  }
}
