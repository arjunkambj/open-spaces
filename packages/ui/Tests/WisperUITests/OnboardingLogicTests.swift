import Testing
import WisperDomain
import WisperEngine

@testable import WisperUI

// MARK: Steps

@Test func practiceIsAStepOnlyWhenThePlatformSuppliesOne() {
  #expect(OnboardingStep.steps(hasPractice: true) == [.welcome, .name, .key, .permissions, .practice, .done])
  #expect(OnboardingStep.steps(hasPractice: false) == [.welcome, .name, .key, .permissions, .done])
}

@Test func stepsMoveForwardAndBackAndStopAtTheEnds() {
  let steps = OnboardingStep.steps(hasPractice: false)
  #expect(OnboardingStep.welcome.previous(in: steps) == nil)
  #expect(OnboardingStep.welcome.next(in: steps) == .name)
  #expect(OnboardingStep.permissions.next(in: steps) == .done)
  #expect(OnboardingStep.done.previous(in: steps) == .permissions)
  #expect(OnboardingStep.done.next(in: steps) == nil)
  #expect(OnboardingStep.practice.next(in: steps) == nil)
}

// MARK: Key step

@Test func withoutAKeyOrAServerTheKeyStepWaits() {
  let action = KeyStepAction(key: "  ", hasSavedKey: false, usesServer: false, server: .openAI)
  #expect(action == .waitForKey)
  #expect(!action.isEnabled)
  #expect(action.buttonTitle == "Continue")
}

@Test func aTypedKeyIsCheckedAndSaved() {
  #expect(KeyStepAction(key: "sk-1", hasSavedKey: false, usesServer: false, server: .openAI) == .saveKey)
  // A new key replaces a saved one.
  #expect(KeyStepAction(key: "sk-2", hasSavedKey: true, usesServer: false, server: .openAI) == .saveKey)
  let server = ServerAddress("http://localhost:11434/v1")
  #expect(KeyStepAction(key: "sk-1", hasSavedKey: false, usesServer: true, server: server) == .saveKey)
}

@Test func aSavedKeyLetsThePersonContinue() {
  let action = KeyStepAction(key: "", hasSavedKey: true, usesServer: false, server: .openAI)
  #expect(action == .useSavedKey)
  #expect(action.isEnabled)
}

@Test func aCustomServerMakesTheKeyOptional() {
  let server = ServerAddress("http://localhost:11434/v1")
  let action = KeyStepAction(key: "", hasSavedKey: false, usesServer: true, server: server)
  #expect(action == .continueWithoutKey)
  #expect(action.isEnabled)
  #expect(action.buttonTitle == "Continue without a key")
}

@Test func anOpenButEmptyServerFieldDoesNotMakeTheKeyOptional() {
  #expect(KeyStepAction(key: "", hasSavedKey: false, usesServer: true, server: .openAI) == .waitForKey)
}

@Test func aServerAddressThatIsTypedButClosedIsIgnored() {
  let server = ServerAddress("http://localhost:11434/v1")
  #expect(KeyStepAction(key: "", hasSavedKey: false, usesServer: false, server: server) == .waitForKey)
  #expect(KeyStepAction(key: "", hasSavedKey: false, usesServer: false, server: .invalid) == .waitForKey)
}

@Test func aBadServerAddressMustBeFixedFirst() {
  let action = KeyStepAction(key: "sk-1", hasSavedKey: true, usesServer: true, server: .invalid)
  #expect(action == .fixServer)
  // The button stays live so pressing it can say what is wrong.
  #expect(action.isEnabled)
}

// MARK: Words

@Test func theLastStepGreetsByName() {
  #expect(OnboardingCopy.allSetTitle(name: " Alex ") == "You are all set, Alex.")
  #expect(OnboardingCopy.allSetTitle(name: "  ") == "You are all set.")
}

@Test func thePermissionsButtonSaysSkipWhileSomethingIsMissing() {
  #expect(OnboardingCopy.permissionsButton(allAllowed: true) == "Continue")
  #expect(OnboardingCopy.permissionsButton(allAllowed: false) == "Skip for now")
}

@Test func theKeyStepSaysWhereTheVoiceGoes() {
  #expect(OnboardingCopy.keyMessage(usesServer: false).contains("only to OpenAI"))
  #expect(OnboardingCopy.keyMessage(usesServer: true).contains("only to that server"))
}

// MARK: Permissions

@Test func everyPermissionHasAReasonAndAConsequence() {
  for permission in Permission.allCases {
    #expect(!PermissionCopy.systemImage(permission).isEmpty)
    #expect(PermissionCopy.reason(permission).hasPrefix("To "))
    #expect(PermissionCopy.consequence(permission).hasPrefix("Without it"))
  }
}

@Test func thePermissionButtonFollowsTheStatus() {
  #expect(PermissionCopy.action(.granted) == nil)
  #expect(PermissionCopy.action(.notDetermined) == "Allow")
  #expect(PermissionCopy.action(.denied) == "Open Settings")
  #expect(PermissionCopy.badge(.granted) == "Allowed")
  #expect(PermissionCopy.badge(.denied) == "Not allowed yet")
  #expect(PermissionCopy.badge(.notDetermined) == "Not allowed yet")
}

@Test func allAllowedNeedsEveryPermission() {
  #expect(PermissionCopy.allAllowed([.microphone: .granted, .accessibility: .granted]))
  #expect(!PermissionCopy.allAllowed([.microphone: .granted, .accessibility: .denied]))
  #expect(!PermissionCopy.allAllowed([.microphone: .notDetermined]))
  #expect(PermissionCopy.allAllowed([:]))
}

// MARK: Through the app model

@MainActor
@Test func aSettingBindingReadsAndWritesTheLibrary() async throws {
  let model = AppModel.demo()
  await model.load()
  let smart = model.settingBinding(\.smartFormatting)
  let keepAudio = model.settingBinding(\.meetings.keepAudio)
  #expect(smart.wrappedValue)

  smart.wrappedValue = false
  keepAudio.wrappedValue = false
  // The copy changes at once; the library a moment later.
  #expect(!model.settings.smartFormatting)
  #expect(!model.settings.meetings.keepAudio)
  try await eventually { try await !model.library.settings().smartFormatting }
  try await eventually { try await !model.library.settings().meetings.keepAudio }
}

@MainActor
@Test func everySnapshotCaseOfSettingsAndOnboardingHasItsOwnName() {
  let names = (SettingsSnapshots.cases + OnboardingSnapshots.cases).map(\.name)
  #expect(Set(names).count == names.count)
  for section in SettingsSection.allCases {
    #expect(names.contains("settings-\(section.rawValue)"))
    #expect(names.contains("settings-\(section.rawValue)-phone"))
  }
  for step in OnboardingStep.allCases {
    #expect(names.contains("onboarding-\(step.rawValue)"))
    #expect(names.contains("onboarding-\(step.rawValue)-phone"))
  }
}

/// Waits until `condition` holds, for up to two seconds.
@MainActor
private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
  for _ in 0..<200 {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("The condition did not become true in time.")
}
