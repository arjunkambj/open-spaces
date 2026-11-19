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
        PartMock { ShortcutsEditor(globeHint: .conflict(.showEmoji)) }
      },
      SnapshotCase("mac-shortcuts-fn-fixed", canvas: .custom(width: 720, height: 560)) {
        PartMock { ShortcutsEditor(globeHint: .nothing, globeUndo: .showEmoji) }
      },
      SnapshotCase("mac-shortcuts-fn-failed", canvas: .custom(width: 720, height: 580)) {
        PartMock { ShortcutsEditor(globeHint: .failed(.showEmoji)) }
      },
      SnapshotCase("mac-shortcuts-recording", canvas: .custom(width: 720, height: 500)) {
        PartMock {
          ShortcutsEditor(
            globeHint: .nothing,
            recording: .handsFree,
            problem: (.pasteLast, ShortcutProblem.reserved(by: "pasting").message)
          )
        }
      },
      SnapshotCase("mac-practice", canvas: .custom(width: 720, height: 400)) {
        PartMock(padding: 0) { PracticeStep(globeHint: .nothing) }
      },
      SnapshotCase(
        "mac-practice-missing",
        canvas: .custom(width: 720, height: 640),
        model: { .demo(onboarded: false, hasAPIKey: false, permissions: [.microphone: .granted]) }
      ) {
        PartMock(padding: 0) { PracticeStep(globeHint: .conflict(.showEmoji)) }
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
      (
        "Pointer over it, password field in use",
        PillState(look: .hint(keys: ["fn"]), meetingSince: nil, shortcutsPaused: true)
      ),
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
      ("Copied", PillState(look: .notice("Copied to the clipboard", canFix: false, isProblem: false))),
      (
        "A question",
        PillState(
          look: .question(
            MacControls.globeKeyQuestion(for: .showEmoji),
            yes: "Fix it",
            no: "Not now"
          )
        )
      ),
      (
        "Hands-free in a long meeting",
        PillState(look: .recording(mode: .dictation, handsFree: true), meetingSince: meeting)
      ),
      ("Being dragged", PillState(look: .hint(keys: ["fn"]), meetingSince: nil, isGrabbed: true)),
    ]
    let now = meeting.addingTimeInterval(247)
    var cases = PillEdge.allCases.map { edge in
      SnapshotCase(
        edge == .bottom ? "mac-pill" : "mac-pill-\(edge.rawValue)",
        canvas: .custom(width: 1100, height: edge.isSide ? 1500 : 1060)
      ) {
        PillSheet(edge: edge, states: states, now: now, longMeeting: meeting.addingTimeInterval(3729))
      }
    }
    cases.append(
      SnapshotCase("mac-pill-corners", canvas: .custom(width: 1100, height: 620)) {
        PillCorners(now: now, since: meeting)
      }
    )
    return cases
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
  @State private var navigation = HubNavigation(defaults: nil)

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

/// Every look of the pill against one screen edge. Each cell stands for a piece of a
/// screen, with a line where that screen's edge is.
private struct PillSheet: View {
  let edge: PillEdge
  let states: [(String, PillState)]
  let now: Date
  /// The clock for the "long meeting" cell: more than an hour in.
  let longMeeting: Date

  var body: some View {
    let columns = Array(repeating: GridItem(.flexible(), spacing: Wisper.Space.l), count: 3)
    VStack(alignment: .leading, spacing: Wisper.Space.m) {
      Text("The pill on the \(edge.rawValue) edge")
        .wisperText(.bodyStrong, color: .white)
      LazyVGrid(columns: columns, spacing: Wisper.Space.l) {
        ForEach(Array(states.enumerated()), id: \.offset) { _, entry in
          VStack(spacing: Wisper.Space.s) {
            ScreenPiece(edge: edge, height: edge.isSide ? 190 : 116) {
              PillBody(
                state: entry.1,
                edge: edge,
                previewLevel: 0.7,
                previewNow: entry.0.contains("long") ? longMeeting : now
              )
            }
            Text(entry.0)
              .wisperText(.caption, color: .white.opacity(0.85))
          }
        }
      }
    }
    .padding(Wisper.Space.l)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background { Desktop() }
  }
}

/// The pill close to the corners of a screen: what opens from it must stay on the screen.
private struct PillCorners: View {
  let now: Date
  let since: Date

  var body: some View {
    let hint = PillState(look: .hint(keys: ["fn"]), meetingSince: nil, shortcutsPaused: true)
    let failure = PillState(
      look: .notice(WisperError.network("timed out").localizedDescription, canFix: false),
      meetingSince: nil
    )
    let busy = PillState(look: .recording(mode: .dictation, handsFree: true), meetingSince: since)
    let size = CGSize(width: 500, height: 250)
    let spots: [(PillEdge, CGPoint, PillState)] = [
      (.bottom, CGPoint(x: 28, y: size.height), hint),
      (.top, CGPoint(x: size.width - 28, y: 0), failure),
      (.left, CGPoint(x: 0, y: 28), busy),
      (.right, CGPoint(x: size.width, y: size.height - 28), hint),
    ]
    VStack(alignment: .leading, spacing: Wisper.Space.m) {
      Text("The pill near a corner: everything stays on the screen")
        .wisperText(.bodyStrong, color: .white)
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(size.width), spacing: Wisper.Space.l), count: 2)) {
        ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
          ScreenPiece(edge: spot.0, height: size.height, allEdges: true) {
            PillBody(state: spot.2, edge: spot.0, foot: spot.1, previewLevel: 0.7, previewNow: now)
          }
        }
      }
    }
    .padding(Wisper.Space.l)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background { Desktop() }
  }
}

/// A piece of a screen with the pill on it. The light line is the edge of the screen.
private struct ScreenPiece<Content: View>: View {
  let edge: PillEdge
  let height: CGFloat
  /// The piece is a whole small screen: all four sides are edges.
  var allEdges = false
  @ViewBuilder var content: Content

  var body: some View {
    content
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .environment(\.colorScheme, .light)
      .background(.white.opacity(0.06))
      .overlay {
        if allEdges { Rectangle().strokeBorder(.white.opacity(0.7), lineWidth: 1) }
      }
      .overlay(alignment: alignment) {
        Rectangle()
          .fill(.white.opacity(0.7))
          .frame(width: edge.isSide ? 1 : nil, height: edge.isSide ? nil : 1)
      }
  }

  private var alignment: Alignment {
    switch edge {
    case .bottom: .bottom
    case .top: .top
    case .left: .leading
    case .right: .trailing
    }
  }
}

/// Stands in for whatever app is behind the pill.
private struct Desktop: View {
  var body: some View {
    LinearGradient(
      colors: [SwiftUI.Color(hex: 0x5B7C99), SwiftUI.Color(hex: 0x8E7AA8), SwiftUI.Color(hex: 0xD9A27E)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
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
