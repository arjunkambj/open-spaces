import Foundation
import WisperDomain

/// The steps of first-run setup, in order.
enum OnboardingStep: String, Hashable, Sendable, CaseIterable {
  case welcome, name, key, permissions, practice, done

  /// The steps to show. Practice is there only when the platform supplies one.
  static func steps(hasPractice: Bool) -> [OnboardingStep] {
    allCases.filter { $0 != .practice || hasPractice }
  }

  func next(in steps: [OnboardingStep]) -> OnboardingStep? {
    guard let index = steps.firstIndex(of: self), index + 1 < steps.count else { return nil }
    return steps[index + 1]
  }

  func previous(in steps: [OnboardingStep]) -> OnboardingStep? {
    guard let index = steps.firstIndex(of: self), index > 0 else { return nil }
    return steps[index - 1]
  }
}

/// What the main button of the key step does, given what has been typed.
enum KeyStepAction: Equatable, Sendable {
  /// Nothing to go on with yet: no key typed, none saved, no custom server.
  case waitForKey
  /// The custom server address cannot be used.
  case fixServer
  /// Check the typed key and store it.
  case saveKey
  /// Nothing typed, but a key is already saved.
  case useSavedKey
  /// Nothing typed and none saved, but a custom server is set: it may not need a key.
  case continueWithoutKey

  /// - usesServer: the "custom server" part is open.
  init(key: String, hasSavedKey: Bool, usesServer: Bool, server: ServerAddress) {
    if usesServer, server == .invalid {
      self = .fixServer
    } else if !APIKeyEntry.isEmpty(key) {
      self = .saveKey
    } else if hasSavedKey {
      self = .useSavedKey
    } else if usesServer, server.address != nil {
      self = .continueWithoutKey
    } else {
      self = .waitForKey
    }
  }

  var buttonTitle: String {
    self == .continueWithoutKey ? "Continue without a key" : "Continue"
  }

  var isEnabled: Bool { self != .waitForKey }
}

/// The words of the last step.
enum OnboardingCopy {
  static func allSetTitle(name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "You are all set." : "You are all set, \(trimmed)."
  }

  /// What Open Wisper is, in three short sentences, on the first step.
  static func welcome(_ idiom: Wisper.Idiom) -> String {
    let how =
      idiom == .phone
      ? "Tap, talk, and your words are written down."
      : "Hold a key and talk. Your words are typed where your cursor is, in any app."
    return "\(how) Meetings get a transcript and notes. Everything stays on this device, "
      + "and you bring your own OpenAI key."
  }

  /// The one thing to remember, on the last step.
  static func allSet(_ idiom: Wisper.Idiom) -> String {
    idiom == .phone
      ? "Tap the big button and speak. In other apps, switch to the Open Wisper keyboard."
      : "Hold your shortcut and speak, in any app. What you say is kept in this window."
  }

  static func keyMessage(usesServer: Bool) -> String {
    usesServer
      ? "Your voice is turned into text by the server you name below. If it needs a key, the key is saved "
        + "on this device only and is sent only to that server."
      : "Your voice is turned into text by OpenAI, using your own key. The key is saved on this device "
        + "only and is sent only to OpenAI."
  }

  static func permissionsButton(allAllowed: Bool) -> String {
    allAllowed ? "Continue" : "Skip for now"
  }
}
