import SwiftUI
import WisperDomain
import WisperEngine
import WisperMac
import WisperUI

/// Still pictures of the Mac app: the whole hub window with each screen, the
/// Settings card, first-run setup, the pill in every state and the menu.
/// Render them with `SnapshotRenderer` (`OpenWisper --snapshots <folder>`).
@MainActor
public enum MacSnapshots {
  public static var cases: [SnapshotCase] {
    hubCases + partCases + pillCases
  }

  static let window = SnapshotCase.Canvas.custom(width: 1180, height: 780)

  private static var hubCases: [SnapshotCase] {
    var cases = HubNavigation.Section.allCases.map { section in
      SnapshotCase("mac-hub-\(section.rawValue)", canvas: window) {
        WindowMock { $0.section = section }
      }
    }
    cases += [
      SnapshotCase("mac-hub-collapsed", canvas: window) {
        WindowMock { $0.sidebarHidden = true }
      },
      SnapshotCase("mac-hub-notices", canvas: window, model: { .demo(hasAPIKey: false) }) {
        WindowMock(
          prepare: { model, controls in
            model.errorMessage = WisperError.network("The connection was lost.").localizedDescription
            controls.needsAccessibility = true
          },
          navigate: { _ in }
        )
      },
      SnapshotCase("mac-hub-meeting-live", canvas: window) {
        WindowMock(
          prepare: { model, _ in model.run { _ = try await $0.meetings.start(title: "Weekly sync") } },
          navigate: { $0.section = .meetings }
        )
      },
      SnapshotCase("mac-settings", canvas: window) {
        WindowMock { $0.showsSettings = true }
      },
      SnapshotCase("mac-settings-small-window", canvas: .custom(width: 920, height: 620)) {
        WindowMock { $0.showsSettings = true }
      },
      SnapshotCase(
        "mac-onboarding",
        canvas: .custom(width: 720, height: 560),
        model: { .demo(onboarded: false, hasAPIKey: false) }
      ) {
        WindowMock { _ in }
      },
    ]
    return cases
  }

  private static var partCases: [SnapshotCase] {
    [
      SnapshotCase("mac-shortcuts", canvas: .custom(width: 720, height: 560)) {
        PartMock { ShortcutsEditor(showsGlobeHint: true) }
      },
      SnapshotCase("mac-shortcuts-recording", canvas: .custom(width: 720, height: 500)) {
        PartMock {
          ShortcutsEditor(
            showsGlobeHint: false,
            recording: .handsFree,
            problem: (.pasteLast, ShortcutProblem.reserved(by: "pasting").message)
          )
        }
      },
      SnapshotCase("mac-practice", canvas: .custom(width: 720, height: 400)) {
        PartMock(padding: 0) { PracticeStep(showsGlobeHint: false) }
      },
      SnapshotCase(
        "mac-practice-missing",
        canvas: .custom(width: 720, height: 640),
        model: { .demo(onboarded: false, hasAPIKey: false, permissions: [.microphone: .granted]) }
      ) {
        PartMock(padding: 0) { PracticeStep(showsGlobeHint: true) }
      },
      SnapshotCase("mac-menu", canvas: .custom(width: 640, height: 380)) {
        PartMock { MenuMock() }
      },
    ]
  }

  private static var pillCases: [SnapshotCase] {
    let meeting = Date(timeIntervalSinceReferenceDate: 0)
    let states: [(String, PillState)] = [
      ("Resting", PillState(look: .resting)),
      ("Pointer over it", PillState(look: .hint(keys: ["fn"]))),
      ("Push to talk", PillState(look: .recording(mode: .dictation, handsFree: false))),
      ("Hands-free", PillState(look: .recording(mode: .dictation, handsFree: true))),
      ("Command mode", PillState(look: .recording(mode: .command, handsFree: false))),
      ("Working", PillState(look: .working)),
      ("No key", PillState(look: .notice("Add your OpenAI key", canFix: true))),
      (
        "A failure",
        PillState(look: .notice(WisperError.network("timed out").localizedDescription, canFix: false))
      ),
      ("Meeting, pill resting", PillState(look: .resting, meetingSince: meeting)),
      (
        "Meeting while dictating",
        PillState(look: .recording(mode: .dictation, handsFree: false), meetingSince: meeting)
      ),
      ("Meeting, pill hidden", PillState(look: .hidden, meetingSince: meeting)),
    ]
    return [
      SnapshotCase("mac-pill", canvas: .custom(width: 1100, height: 560)) {
        PillSheet(states: states, now: meeting.addingTimeInterval(247))
      }
    ]
  }
}

// MARK: - Scaffolding

/// Gives a view the objects the app would give it, made from the snapshot's own model.
private struct Staged<Content: View>: View {
  @Environment(AppModel.self) private var model
  @State private var controls: MacControls?
  var prepare: @MainActor (AppModel, MacControls) -> Void = { _, _ in }
  @ViewBuilder var content: (MacControls) -> Content

  var body: some View {
    ZStack {
      if let controls {
        content(controls).environment(controls)
      }
    }
    .onAppear {
      guard controls == nil else { return }
      let made = MacControls(model: model)
      prepare(model, made)
      controls = made
    }
  }
}

/// The hub as it sits in its window: a title bar's worth of room at the top and the window buttons.
private struct WindowMock: View {
  var prepare: @MainActor (AppModel, MacControls) -> Void = { _, _ in }
  var navigate: @MainActor (HubNavigation) -> Void
  @State private var navigation = HubNavigation()

  var body: some View {
    Staged(prepare: prepare) { _ in
      HubView(navigation: navigation)
        .safeAreaPadding(.top, HubMetrics.minimumStrip)
        .overlay(alignment: .topLeading) {
          HStack(spacing: 8) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { hex in
              Circle().fill(SwiftUI.Color(hex: hex)).frame(width: 12, height: 12)
            }
          }
          .padding(.leading, 10)
          .padding(.top, 10)
        }
    }
    .onAppear { navigate(navigation) }
  }
}

/// A part of a screen on the panel colour, with room around it.
private struct PartMock<Content: View>: View {
  var padding = Wisper.Space.xl
  @ViewBuilder var content: Content

  var body: some View {
    Staged { _ in
      content
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Wisper.Color.panel)
    }
  }
}

private struct MenuMock: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let microphones = [
      AudioDevice(id: "built-in", name: "MacBook Pro Microphone", isDefault: true),
      AudioDevice(id: "usb", name: "Studio Microphone"),
    ]
    HStack(alignment: .top, spacing: Wisper.Space.s) {
      MenuPreview(entries: MenuBarContent.entries(for: model, microphones: microphones))
      MenuPreview(entries: MenuBarContent.microphoneEntries(microphones, chosen: nil))
        .padding(.top, 118)
    }
  }
}

/// Every look of the pill, side by side on something like a desktop.
private struct PillSheet: View {
  let states: [(String, PillState)]
  let now: Date

  var body: some View {
    let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 3)
    LazyVGrid(columns: columns, spacing: 0) {
      ForEach(Array(states.enumerated()), id: \.offset) { _, entry in
        VStack(spacing: Wisper.Space.s) {
          PillBody(state: entry.1, previewLevel: 0.7, previewNow: now)
            .frame(height: 92, alignment: .bottom)
            .environment(\.colorScheme, .light)
          Text(entry.0)
            .wisperText(.caption, color: .white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Wisper.Space.m)
      }
    }
    .padding(Wisper.Space.l)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      // Stands in for whatever app is behind the pill.
      LinearGradient(
        colors: [SwiftUI.Color(hex: 0x5B7C99), SwiftUI.Color(hex: 0x8E7AA8), SwiftUI.Color(hex: 0xD9A27E)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }
}

extension PillState {
  fileprivate init(look: Look) {
    self.init(look: look, meetingSince: nil)
  }
}

extension SwiftUI.Color {
  /// A plain colour for snapshot scaffolding (window buttons, the fake desktop). Screens use `Wisper.Color`.
  fileprivate init(hex: Int) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}
