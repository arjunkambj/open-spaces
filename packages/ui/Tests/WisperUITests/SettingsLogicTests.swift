import Foundation
import Testing
import WisperDomain

@testable import WisperUI

// MARK: Sections

@Test func shortcutsSectionIsListedOnlyWhenThePlatformHasAnEditor() {
  let with = SettingsSection.Group.allCases.flatMap { SettingsSection.sections(in: $0, hasShortcuts: true) }
  let without = SettingsSection.Group.allCases.flatMap {
    SettingsSection.sections(in: $0, hasShortcuts: false)
  }
  #expect(with == SettingsSection.allCases)
  #expect(without == SettingsSection.allCases.filter { $0 != .shortcuts })
}

@Test func everySectionHasATitleAndAnIcon() {
  for section in SettingsSection.allCases {
    #expect(!section.title.isEmpty)
    #expect(!section.systemImage.isEmpty)
  }
  #expect(Set(SettingsSection.allCases.map(\.title)).count == SettingsSection.allCases.count)
}

// MARK: Server address

@Test(arguments: ["", "   ", "\n"])
func anEmptyServerAddressMeansOpenAI(text: String) {
  let address = ServerAddress(text)
  #expect(address == .openAI)
  #expect(address.isValid)
  #expect(address.address == nil)
}

@Test(arguments: [
  ("http://localhost:11434/v1", "http://localhost:11434/v1"),
  ("  https://proxy.example.com/v1/  ", "https://proxy.example.com/v1"),
  ("HTTPS://Example.com", "HTTPS://Example.com"),
  ("http://192.168.1.20:8080", "http://192.168.1.20:8080"),
])
func aWebAddressIsKeptAndTidied(text: String, expected: String) {
  #expect(ServerAddress(text) == .custom(expected))
  #expect(ServerAddress(text).address == expected)
}

@Test(arguments: [
  "localhost:11434", "example.com/v1", "ftp://example.com", "https://", "http://my server", "sk-123",
])
func anythingElseIsNotAServerAddress(text: String) {
  let address = ServerAddress(text)
  #expect(address == .invalid)
  #expect(!address.isValid)
  #expect(address.address == nil)
}

@Test func serverDraftSavesAnEmptyStringForOpenAI() {
  #expect(ServerDraft.check("  ") == .save(""))
  #expect(ServerDraft.check("http://localhost:1234/v1/") == .save("http://localhost:1234/v1"))
  #expect(ServerDraft.check("nope") == .reject(ServerAddress.invalidMessage))
}

// MARK: Models

@Test func modelPickerOffersTheSuggestionsThenCustom() {
  let options = ModelChoice.options(suggested: ["a", "b"])
  #expect(options == [.named("a"), .named("b"), .custom])
  #expect(options.map(\.title) == ["a", "b", "Custom…"])
}

@Test func aModelThatIsNotSuggestedShowsAsCustom() {
  let suggested = Settings.suggestedTextModels
  #expect(
    ModelChoice.selection(current: Settings.defaultTextModel, suggested: suggested, typing: false)
      == .named(Settings.defaultTextModel)
  )
  #expect(ModelChoice.selection(current: "my-own-model", suggested: suggested, typing: false) == .custom)
  #expect(
    ModelChoice.selection(current: Settings.defaultTextModel, suggested: suggested, typing: true) == .custom
  )
}

@Test func theDefaultModelsAreAmongTheSuggestions() {
  #expect(Settings.suggestedTranscriptionModels.contains(Settings.defaultTranscriptionModel))
  #expect(Settings.suggestedTextModels.contains(Settings.defaultTextModel))
}

@Test func aTypedModelNameIsTrimmedAndNeverEmpty() {
  #expect(ModelChoice.typedName("  llama-3.3-70b ") == "llama-3.3-70b")
  #expect(ModelChoice.typedName("   ") == nil)
}

// MARK: Language and microphone

@Test func languagesStartWithAutomaticAndAreSortedByName() {
  let codes = LanguageOptions.codes
  #expect(codes.first == .some(nil))
  #expect(codes.count == SpokenLanguage.all.count + 1)
  let names = codes.dropFirst().map(LanguageOptions.title)
  #expect(names == names.sorted())
  #expect(LanguageOptions.title(nil) == "Detect automatically")
  #expect(LanguageOptions.title("hi") == "Hindi")
  #expect(LanguageOptions.title("xx") == "xx")
}

@Test func microphonesStartWithTheSystemDefault() {
  let devices = [
    AudioDevice(id: "built-in", name: "MacBook Pro Microphone", isDefault: true),
    AudioDevice(id: "headset", name: "Studio Headset"),
  ]
  #expect(MicrophoneOptions.ids(devices: devices, selected: nil) == [nil, "built-in", "headset"])
  #expect(MicrophoneOptions.title(nil, devices: devices) == "System default")
  #expect(MicrophoneOptions.title("headset", devices: devices) == "Studio Headset")
  #expect(MicrophoneOptions.summary(devices: devices, selected: nil) == "Using MacBook Pro Microphone.")
  #expect(
    MicrophoneOptions.summary(devices: devices, selected: "headset") == "Used for dictation and meetings."
  )
}

@Test func anUnpluggedMicrophoneStaysInTheListAndIsExplained() {
  let devices = [AudioDevice(id: "built-in", name: "MacBook Pro Microphone", isDefault: true)]
  #expect(MicrophoneOptions.ids(devices: devices, selected: "gone") == [nil, "built-in", "gone"])
  #expect(MicrophoneOptions.title("gone", devices: devices) == "Not connected")
  #expect(MicrophoneOptions.summary(devices: devices, selected: "gone").contains("not connected"))
  #expect(MicrophoneOptions.summary(devices: [], selected: nil).contains("system settings"))
}

// MARK: Name

@Test func aNameIsTrimmedAndCannotBeEmpty() {
  #expect(NameDraft.check("  Alex ") == .save("Alex"))
  #expect(NameDraft.check("   ") == .reject("Your name cannot be empty."))
}

// MARK: Agents

@Test func theClaudeCommandQuotesThePath() {
  let command = AgentSetup.claudeCommand(toolPath: "/Applications/Open Wisper.app/Contents/MacOS/wisper")
  #expect(
    command
      == #"claude mcp add --scope user open-wisper -- "/Applications/Open Wisper.app/Contents/MacOS/wisper" mcp"#
  )
}

@Test func aPathWithShellCharactersIsEscaped() {
  #expect(AgentSetup.shellQuoted(#"/Users/a"b/$HOME/`x`\y"#) == #""/Users/a\"b/\$HOME/\`x\`\\y""#)
}

@Test func theSettingsBlockIsValidJSONWithThePathAndTheMcpArgument() throws {
  let path = #"/Users/sam/My "Apps"/Open Wisper.app/Contents/MacOS/wisper"#
  let json = AgentSetup.jsonConfig(toolPath: path)
  let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
  let servers = object?["mcpServers"] as? [String: Any]
  let server = servers?["open-wisper"] as? [String: Any]
  #expect(server?["command"] as? String == path)
  #expect(server?["args"] as? [String] == ["mcp"])
  // Slashes stay readable.
  #expect(json.contains("/Open Wisper.app/Contents/MacOS/wisper"))
}

// MARK: Version, privacy, key

@Test func theVersionFallsBackToDev() {
  #expect(AppVersion.text(info: ["CFBundleShortVersionString": "1.2.0"]) == "1.2.0")
  #expect(AppVersion.text(info: ["CFBundleShortVersionString": ""]) == "dev")
  #expect(AppVersion.text(info: [:]) == "dev")
  #expect(AppVersion.text(info: nil) == "dev")
}

@Test func theHistoryCountReadsNaturally() {
  #expect(PrivacyCopy.historyCount(0) == "There is nothing in your history.")
  #expect(PrivacyCopy.historyCount(1) == "1 dictation, with its audio.")
  #expect(PrivacyCopy.historyCount(6) == "6 dictations, with their audio.")
  #expect(PrivacyCopy.deleteWarning(count: 1).contains("1 dictation and its audio"))
  #expect(PrivacyCopy.deleteWarning(count: 6).contains("6 dictations and their audio"))
}

@Test func everyRetentionChoiceIsExplained() {
  for retention in HistoryRetention.allCases {
    #expect(!PrivacyCopy.retention(retention).isEmpty)
  }
  #expect(PrivacyCopy.retention(.never) != PrivacyCopy.retention(.forever))
}

@Test func theDataFolderIsShownFromTheHomeFolder() {
  let folder = URL(fileURLWithPath: "/Users/sam/Library/Application Support/Open Wisper", isDirectory: true)
  #expect(PrivacyCopy.shortPath(folder, home: "/Users/sam") == "~/Library/Application Support/Open Wisper")
  #expect(PrivacyCopy.shortPath(folder, home: "/Users/sa") == folder.path)
  #expect(PrivacyCopy.shortPath(URL(fileURLWithPath: "/Users/sam"), home: "/Users/sam") == "~")
}

@Test func keyErrorsAreExplainedWhereThePersonIs() {
  #expect(APIKeyEntry.isEmpty("  \n"))
  #expect(!APIKeyEntry.isEmpty(" sk-1 "))
  #expect(APIKeyEntry.message(for: WisperError.missingAPIKey) == "Paste your key first.")
  #expect(!APIKeyEntry.message(for: WisperError.invalidAPIKey).contains("Settings"))
  #expect(APIKeyEntry.message(for: WisperError.rateLimited) == WisperError.rateLimited.localizedDescription)
}

@Test func keyStatusNamesWhereTheKeyGoes() {
  #expect(OpenAICopy.keyStatus(hasKey: true, customHost: nil).contains("only to OpenAI"))
  #expect(OpenAICopy.keyStatus(hasKey: true, customHost: "localhost").contains("sent to localhost"))
  #expect(OpenAICopy.keyStatus(hasKey: false, customHost: "localhost").contains("No key is saved"))
  #expect(OpenAICopy.keyStatus(hasKey: false, customHost: nil).contains("Add your key"))
  #expect(PrivacyCopy.destinationTitle(customServer: true).contains("custom server"))
}

// MARK: The key belongs to a server

@Test(arguments: [
  "http://models.example.com/v1", "http://192.168.1.20:8080", "HTTP://Example.com/api",
])
func plainHttpToAnotherMachineIsNotPrivate(text: String) {
  #expect(ServerAddress(text).isNotPrivate)
}

@Test(arguments: [
  "", "https://proxy.example.com/v1", "http://localhost:11434/v1", "http://127.0.0.1:1234",
  "http://LOCALHOST:8080", "not an address",
])
func openAIHttpsAndThisDeviceArePrivate(text: String) {
  #expect(!ServerAddress(text).isNotPrivate)
}

@Test func theAddressFieldFollowsTheSharedRule() {
  // Whatever the field accepts, the app model and the network code accept too, and the reverse.
  for text in [
    "http://localhost:11434", "https://Proxy.Example.com/v1/", "localhost:11434", "ftp://x.y", "a b",
  ] {
    let shared = try? APIServer(address: text)
    #expect((ServerAddress(text).address != nil) == (shared != nil))
    #expect(ServerAddress(text).server?.host == shared?.host)
  }
  #expect(ServerAddress("").server == .openAI)
  #expect(ServerAddress("").customHost == nil)
  #expect(ServerAddress("https://Proxy.Example.com/v1").customHost == "proxy.example.com")
  #expect(ServerAddress("nope").customHost == nil)
}

@Test func theKeyLineNamesTheServerTheKeyGoesTo() {
  #expect(OpenAICopy.keyStatus(hasKey: true, customHost: nil).contains("only to OpenAI"))
  #expect(
    OpenAICopy.keyStatus(hasKey: true, customHost: "proxy.example.com")
      .contains("sent to proxy.example.com, not to OpenAI")
  )
  // After the address changed to another server, the key that was saved is not used there.
  let other = OpenAICopy.keyStatus(hasKey: false, customHost: "proxy.example.com")
  #expect(other.contains("No key is saved for proxy.example.com"))
  #expect(other.contains("never sent to this one"))
  #expect(
    OpenAICopy.keyDialogTitle(hasKey: false, customHost: "proxy.example.com")
      == "Add the key for proxy.example.com"
  )
  #expect(OpenAICopy.keyDialogTitle(hasKey: true, customHost: nil) == "Change your OpenAI key")
  #expect(OpenAICopy.keyDialogSubtitle(customHost: "proxy.example.com").contains("not to OpenAI"))
  #expect(ServerAddress.keyNote == "Your key will be sent to this server instead of OpenAI.")
}

@Test func aMissingKeyIsOnlyAWarningForOpenAIItself() {
  #expect(KeyNeed.isMissing(hasKey: false, settings: Settings()))
  #expect(!KeyNeed.isMissing(hasKey: true, settings: Settings()))
  // A server of the person's own may not need a key.
  #expect(!KeyNeed.isMissing(hasKey: false, settings: Settings(apiBaseURL: "http://localhost:11434/v1")))
  // An address that cannot be used is another problem, said elsewhere.
  #expect(!KeyNeed.isMissing(hasKey: false, settings: Settings(apiBaseURL: "nope")))
}

@Test func aSavedKeyCountsOnlyForTheServerItWasSavedFor() {
  let openAI = Settings()
  let proxy = Settings(apiBaseURL: "https://proxy.example.com/v1")
  #expect(KeyNeed.savedKeyApplies(hasKey: true, stored: openAI, typed: .openAI))
  #expect(!KeyNeed.savedKeyApplies(hasKey: false, stored: openAI, typed: .openAI))
  // Typing another server: the key saved for OpenAI is not one for it.
  #expect(
    !KeyNeed.savedKeyApplies(hasKey: true, stored: openAI, typed: ServerAddress("https://proxy.example.com"))
  )
  // Going back to OpenAI: the key saved for the proxy is not an OpenAI key.
  #expect(!KeyNeed.savedKeyApplies(hasKey: true, stored: proxy, typed: .openAI))
  // The same host, written another way, is the same server.
  #expect(
    KeyNeed.savedKeyApplies(
      hasKey: true,
      stored: proxy,
      typed: ServerAddress("https://PROXY.example.com/api")
    )
  )
  #expect(!KeyNeed.savedKeyApplies(hasKey: true, stored: proxy, typed: .invalid))
}

// MARK: Code blocks

@Test func aCodeLineKeepsItsIndentApartFromItsText() {
  let lines = CodeLine.lines(of: "{\n  \"a\": {\n    \"b\": 1\n  }\n}")
  #expect(lines.map(\.indent) == ["", "  ", "    ", "  ", ""])
  #expect(lines.map(\.code) == ["{", "\"a\": {", "\"b\": 1", "}", "}"])
  // Nothing of the text is lost, blank lines included.
  let text = AgentSetup.jsonConfig(toolPath: "/Applications/Open Wisper.app/Contents/MacOS/wisper")
  #expect(CodeLine.lines(of: text).map { $0.indent + $0.code }.joined(separator: "\n") == text)
  #expect(CodeLine.lines(of: "a\n\nb").count == 3)
  #expect(CodeLine.lines(of: "one line") == [CodeLine(indent: "", code: "one line")])
}
