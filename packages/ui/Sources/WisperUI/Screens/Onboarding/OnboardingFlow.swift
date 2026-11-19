import SwiftUI
import WisperDomain
import WisperEngine

/// First-run setup: name, OpenAI key, permissions, then the platform's practice step.
/// Calls `AppModel.finishOnboarding(userName:)` at the end. Reads `AppModel` from the environment.
/// - practice: a last step supplied by the platform (macOS: try the shortcut; iOS: turn on the keyboard).
public struct OnboardingFlow: View {
  private let practice: AnyView?

  public init(practice: AnyView? = nil) {
    self.practice = practice
  }

  public var body: some View {
    // CONTRACT STUB: the screen builder replaces this body.
    Text("OnboardingFlow")
  }
}
