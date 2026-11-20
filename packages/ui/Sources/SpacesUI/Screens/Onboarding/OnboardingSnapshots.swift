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
      cases.append(flow("onboarding-\(step.rawValue)-phone", OnboardingPreview(step: step), onPhone: true))
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
      flow(
        "onboarding-key-error-phone",
        OnboardingPreview(
          step: .key,
          key: "not-a-key",
          keyError: APIKeyEntry.message(for: SpacesError.invalidAPIKey)
        ),
        onPhone: true
      ),
      flow("onboarding-key-checking", OnboardingPreview(step: .key, key: "sk-demo-key", isChecking: true)),
      flow("onboarding-key-saved", OnboardingPreview(step: .key), hasAPIKey: true),
      flow("onboarding-key-server", OnboardingPreview(step: .key, server: "http://localhost:11434/v1")),
      flow(
        "onboarding-key-server-phone",
        OnboardingPreview(step: .key, server: "http://localhost:11434/v1"),
        onPhone: true
      ),
      flow(
        "onboarding-key-server-not-private",
        OnboardingPreview(step: .key, server: "http://models.example.com/v1")
      ),
      flow(
        "onboarding-key-server-not-private-phone",
        OnboardingPreview(step: .key, server: "http://192.168.1.20:8080/v1"),
        onPhone: true
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
    permissions: [Permission: PermissionStatus] = [:],
    onPhone: Bool = false
  ) -> SnapshotCase {
    SnapshotCase(
      name,
      canvas: onPhone ? .phone : window,
      model: {
        SetupSnapshotModels.make(
          onboarded: preview.step != .welcome && preview.step != .name,
          hasAPIKey: hasAPIKey,
          permissions: permissions,
          onPhone: onPhone,
          settings: { $0.onboardedAt = nil }
        )
      }
    ) {
      OnboardingFlow(practice: AnyView(PracticeStandIn()), preview: preview)
    }
  }
}

/// Stands in for the practice step the platform supplies.
private struct PracticeStandIn: View {
  @Environment(\.spacesIdiom) private var idiom

  var body: some View {
    VStack(spacing: Spaces.Space.xl) {
      Text("Try it once")
        .spacesText(.hero)
      Text(
        idiom == .phone
          ? "The iPhone app puts its keyboard step here." : "The Mac app puts its shortcut step here."
      )
      .spacesText(.body, color: Spaces.Color.textSecondary)
      .multilineTextAlignment(.center)
      KeyCapRow(["fn"])
    }
    .padding(Spaces.Space.xl)
  }
}
