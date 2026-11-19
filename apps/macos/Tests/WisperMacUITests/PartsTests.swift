import AppKit
import Foundation
import SwiftUI
import Testing
import WisperDomain
import WisperEngine
import WisperMac

@testable import WisperMacUI

@MainActor
@Suite struct PillStateTests {
  private func resolve(
    phase: DictationEngine.Phase = .idle,
    showsRecording: Bool = true,
    isWrappingUp: Bool = false,
    notice: MacControls.Notice? = nil,
    meetingSince: Date? = nil,
    isEnabled: Bool = true,
    isHovered: Bool = false
  ) -> PillState {
    PillState.resolve(
      phase: phase,
      showsRecording: showsRecording,
      isWrappingUp: isWrappingUp,
      notice: notice,
      meetingSince: meetingSince,
      isEnabled: isEnabled,
      isHovered: isHovered,
      hintKeys: ["fn"]
    )
  }

  private let recording = DictationEngine.Phase.recording(mode: .dictation, since: Date(), handsFree: true)

  @Test func restsAndGrowsUnderThePointer() {
    #expect(resolve().look == .resting)
    #expect(resolve(isHovered: true).look == .hint(keys: ["fn"]))
  }

  @Test func turnedOffItIsHiddenButStillShowsWhatIsGoingOn() {
    #expect(resolve(isEnabled: false).look == .hidden)
    #expect(resolve(isEnabled: false, isHovered: true).look == .hidden)
    #expect(resolve(phase: recording, isEnabled: false).look == .recording(mode: .dictation, handsFree: true))
    #expect(resolve(phase: .processing(mode: .dictation), isEnabled: false).look == .working)
    #expect(resolve(phase: .failed(message: "No."), isEnabled: false).look == .notice("No.", canFix: false))
  }

  @Test func aRecordingNotYetRevealedLooksLikeNothing() {
    #expect(resolve(phase: recording, showsRecording: false).look == .resting)
    #expect(resolve(phase: recording, showsRecording: false, isEnabled: false).look == .hidden)
  }

  @Test func wrappingUpAlreadyLooksLikeWorking() {
    #expect(resolve(phase: recording, isWrappingUp: true).look == .working)
  }

  @Test func aNoticeComesFirst() {
    let notice = MacControls.Notice(message: "Add your OpenAI key", fix: .settings)
    #expect(resolve(phase: recording, notice: notice).look == .notice("Add your OpenAI key", canFix: true))
  }

  @Test func newsIsNotShownAsAProblem() {
    let copied = MacControls.Notice(message: "Copied to the clipboard", isProblem: false)
    #expect(
      resolve(notice: copied).look == .notice("Copied to the clipboard", canFix: false, isProblem: false)
    )
  }

  @Test func theHintKnowsWhenShortcutsCannotBeHeard() {
    let state = PillState.resolve(
      phase: .idle,
      showsRecording: false,
      isWrappingUp: false,
      notice: nil,
      meetingSince: nil,
      isEnabled: true,
      isHovered: true,
      hintKeys: ["fn"],
      shortcutsPaused: true
    )
    #expect(state.look == .hint(keys: ["fn"]))
    #expect(state.shortcutsPaused)
    #expect(!resolve(isHovered: true).shortcutsPaused)
  }

  @Test func aMeetingShowsEvenWhenThePillIsHidden() {
    let since = Date()
    let state = resolve(meetingSince: since, isEnabled: false)
    #expect(state.look == .hidden)
    #expect(state.meetingSince == since)
    #expect(!state.isEmpty)
    #expect(resolve(isEnabled: false).isEmpty)
  }
}

@MainActor
@Suite struct PillViewTests {
  /// Puts the pill in a window-sized view, as the app does, and lets it lay out.
  private func host(_ stage: Stage, pointer: PillPointer) async -> NSView {
    let view = NSHostingView(
      rootView: PillView(pointer: pointer).environment(stage.model).environment(stage.controls)
    )
    view.frame = CGRect(x: 0, y: 0, width: 480, height: 150)
    view.layoutSubtreeIfNeeded()
    await settle { !pointer.hotFrame.isEmpty }
    return view
  }

  @Test func tellsItsWindowWhereItCanBeClicked() async {
    let stage = await Stage()
    let pointer = PillPointer()
    let view = await host(stage, pointer: pointer)
    // The resting pill: 40 x 8, centred, just above the bottom edge.
    #expect(pointer.hotFrame.size == CGSize(width: 40, height: 8))
    #expect(abs(pointer.hotFrame.midX - 240) < 1)
    #expect(pointer.hotFrame.maxY > 140 && pointer.hotFrame.maxY <= 150)

    pointer.isHovered = true
    await settle { pointer.hotFrame.height > 8 }
    #expect(pointer.hotFrame.height == 30, "Under the pointer it grows, and the hint above is not part of it")
    #expect(pointer.hotFrame.width > 50)
    _ = view
  }

  @Test func hasNothingToClickWhenSwitchedOff() async {
    let stage = await Stage()
    let pointer = PillPointer()
    let view = await host(stage, pointer: pointer)
    stage.model.update { $0.showPill = false }
    await settle { pointer.hotFrame.isEmpty }
    #expect(pointer.hotFrame.isEmpty)
    // It comes back for as long as something is going on.
    stage.controls.toggleHandsFree()
    await settle { !pointer.hotFrame.isEmpty }
    #expect(pointer.hotFrame.height == 28)
    stage.controls.cancel()
    await settle { pointer.hotFrame.isEmpty }
    #expect(pointer.hotFrame.isEmpty)
    _ = view
  }
}

@MainActor
@Suite struct MenuBarContentTests {
  private let microphones = [
    AudioDevice(id: "built-in", name: "MacBook Microphone", isDefault: true),
    AudioDevice(id: "usb", name: "Desk Microphone"),
  ]

  private func titles(_ entries: [MenuEntry]) -> [String] {
    entries.filter { $0.kind != .separator }.map(\.title)
  }

  @Test func theMenuReadsTopToBottom() async {
    let stage = await Stage()
    let entries = MenuBarContent.entries(for: stage.model, microphones: microphones)
    let titles = titles(entries)
    #expect(titles.first == "Open Open Wisper")
    #expect(titles.last == "Quit Open Wisper")
    #expect(titles.contains("Start Meeting Recording"))
    #expect(titles.contains("Paste Last Transcript"))
    #expect(titles.contains("Settings…"))
    #expect(titles.contains("Hold fn to dictate"))
    let meeting = entries.first { $0.kind == .action(.toggleMeeting) }
    #expect(meeting?.shortcut == Settings.defaultShortcuts[.toggleMeeting])
  }

  @Test func itOffersAnUpdateCheckOnlyWhereTheAppCanUpdateItself() async {
    // The demo, and a build that is not a finished app, have no way to update.
    let without = await Stage()
    let plain = MenuBarContent.entries(for: without.model, microphones: microphones)
    #expect(!plain.contains { $0.kind == .action(.checkForUpdates) })
    MenuBarContent.perform(.checkForUpdates, model: without.model, controls: without.controls)

    let checks = Checks()
    let stage = await Stage(host: HostActions(checkForUpdates: { checks.count += 1 }))
    let entries = MenuBarContent.entries(for: stage.model, microphones: microphones)
    let titles = titles(entries)
    #expect(titles.contains("Check for Updates…"))
    // It sits right under Settings, and Quit stays last.
    #expect(titles.firstIndex(of: "Check for Updates…") == titles.firstIndex(of: "Settings…").map { $0 + 1 })
    #expect(titles.last == "Quit Open Wisper")
    MenuBarContent.perform(.checkForUpdates, model: stage.model, controls: stage.controls)
    #expect(checks.count == 1)
  }

  @Test func anUpdateThatIsWaitingIsOfferedByItsVersion() async {
    let stage = await Stage(host: HostActions(checkForUpdates: {}))
    let entries = MenuBarContent.entries(for: stage.model, microphones: microphones, waitingUpdate: "0.2.0")
    let update = entries.first { $0.kind == .action(.checkForUpdates) }
    #expect(update?.title == "Install Update 0.2.0…")
    #expect(MenuBarContent.updateTitle(waiting: "") == "Check for Updates…")
  }

  @MainActor
  private final class Checks {
    var count = 0
  }

  @Test func itOffersToStopAMeetingThatIsRunning() async {
    let stage = await Stage()
    stage.controls.toggleMeeting()
    await settle { stage.model.meetings.isRecording }
    let entries = MenuBarContent.entries(for: stage.model, microphones: microphones)
    #expect(titles(entries).contains("Stop Meeting Recording"))
    #expect(MenuBarContent.icon(for: stage.model, controls: stage.controls) == .meeting)
    stage.controls.toggleHandsFree()
    #expect(MenuBarContent.icon(for: stage.model, controls: stage.controls) == .dictating)
    stage.controls.cancel()
    stage.controls.toggleMeeting()
    await settle { !stage.model.meetings.isRecording }
    #expect(MenuBarContent.icon(for: stage.model, controls: stage.controls) == .idle)
  }

  @Test func aKeyThatIsOnlyPassingThroughDoesNotChangeTheMenuBarPicture() async {
    let stage = await Stage(revealDelay: .seconds(5))
    // fn goes down. It records at once, but may still turn out to be fn + arrow.
    stage.press(.down(.pushToTalk))
    #expect(stage.model.dictation.isRecording)
    #expect(MenuBarContent.icon(for: stage.model, controls: stage.controls) == .idle)
    stage.press(.abandoned(.pushToTalk, replacedBy: nil))
    #expect(MenuBarContent.icon(for: stage.model, controls: stage.controls) == .idle)
  }

  @Test func theChosenMicrophoneIsTicked() {
    let auto = MenuBarContent.microphoneEntries(microphones, chosen: nil)
    #expect(auto.first?.title == "Mac’s Choice (MacBook Microphone)")
    #expect(auto.filter(\.isChecked).map(\.kind) == [.action(.pickMicrophone(nil))])
    let usb = MenuBarContent.microphoneEntries(microphones, chosen: "usb")
    #expect(usb.filter(\.isChecked).map(\.title) == ["Desk Microphone"])
    let gone = MenuBarContent.microphoneEntries(microphones, chosen: "unplugged")
    #expect(gone.last?.kind == .note)
    #expect(gone.last?.isChecked == true)
  }

  @Test func choosingAMicrophoneSavesIt() async {
    let stage = await Stage()
    MenuBarContent.perform(.pickMicrophone("usb"), model: stage.model, controls: stage.controls)
    #expect(stage.model.settings.microphoneID == "usb")
    MenuBarContent.perform(.openSettings, model: stage.model, controls: stage.controls)
    MenuBarContent.perform(.openHub, model: stage.model, controls: stage.controls)
    #expect(stage.opened.destinations == [.settings, .hub])
  }

  @Test func theHintFollowsTheShortcut() {
    var settings = Settings()
    #expect(MenuBarContent.dictationHint(settings) == "Hold fn to dictate")
    settings.shortcuts[.pushToTalk] = KeyCombo()
    #expect(MenuBarContent.dictationHint(settings) == "Click the pill to dictate")
  }

  @Test func longDictationsAreCutShort() {
    #expect(MenuBarContent.preview(of: "Short one.") == "“Short one.”")
    let long = MenuBarContent.preview(of: String(repeating: "word ", count: 30))
    #expect(long.count <= 46)
    #expect(long.hasSuffix("…”"))
    #expect(MenuBarContent.preview(of: "First line\nSecond line") == "“First line”")
  }

  @Test func thePillMenuOffersToHideAndToComeBack() async {
    let stage = await Stage()
    var entries = MenuBarContent.pillEntries(for: stage.model, controls: stage.controls, microphones: [])
    #expect(entries.first?.kind == .action(.hidePill))
    MenuBarContent.perform(.hidePill, model: stage.model, controls: stage.controls)
    entries = MenuBarContent.pillEntries(for: stage.model, controls: stage.controls, microphones: [])
    #expect(entries.first?.kind == .action(.showPill))
    MenuBarContent.perform(.showPill, model: stage.model, controls: stage.controls)
    #expect(stage.controls.pillHiddenUntil == nil)
  }
}

@MainActor
@Suite struct HubNavigationTests {
  @Test func remembersItsChoices() throws {
    let name = "open-wisper-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    let first = HubNavigation(defaults: defaults)
    #expect(first.section == .home)
    #expect(first.theme == .light, "Light until the person chooses, whatever the Mac is set to")
    first.section = .snippets
    first.theme = .dark
    first.sidebarHidden = true

    let second = HubNavigation(defaults: defaults)
    #expect(second.section == .snippets)
    #expect(second.theme == .dark)
    #expect(second.sidebarHidden)
  }

  @Test func showingAMeetingGoesToMeetingsAndClosesSettings() {
    let navigation = HubNavigation()
    navigation.showsSettings = true
    let id = UUID()
    navigation.show(meeting: id)
    #expect(navigation.section == .meetings)
    #expect(navigation.meeting == id)
    #expect(!navigation.showsSettings)
  }

  @Test func themesMapToAppearances() {
    #expect(HubNavigation.Theme.system.appearance == nil)
    #expect(HubNavigation.Theme.dark.appearance?.name == .darkAqua)
    #expect(HubNavigation.Theme.light.appearance?.name == .aqua)
  }
}

@MainActor
@Suite struct WatchTests {
  @Test func reportsNowAndOnEveryChange() async {
    let navigation = HubNavigation()
    var seen: [HubNavigation.Section] = []
    let watch = Watch({ navigation.section }) { seen.append($0) }
    #expect(seen == [.home])
    navigation.section = .style
    await settle { seen.count == 2 }
    navigation.section = .style  // No change: no report.
    navigation.section = .meetings
    await settle { seen.count == 3 }
    #expect(seen == [.home, .style, .meetings])
    _ = watch
  }
}
