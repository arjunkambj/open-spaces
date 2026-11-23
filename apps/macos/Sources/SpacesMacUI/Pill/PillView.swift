import Observation
import SpacesDomain
import SpacesEngine
import SpacesMac
import SpacesUI
import SwiftUI

/// What the pill's window tells the pill, and the pill tells its window.
///
/// The pill lives in a window that never takes focus and lets clicks through,
/// so the window watches the pointer itself: it sets `isHovered`, and reads
/// `hotFrame` to know where the pill can be clicked. The window also says
/// where the pill is (`edge`, `foot`) and whether it is being dragged.
@MainActor
@Observable
public final class PillPointer {
  /// The pointer is over the pill.
  public var isHovered = false
  /// The screen edge the pill sits against.
  public var edge = PillEdge.bottom
  /// The point the pill is attached to, in the coordinates of `PillView` (origin at the top
  /// left). `nil` is the middle of `edge`. While `isFloating`, it is the middle of the pill.
  public var foot: CGPoint?
  /// The pill is being carried by the pointer: it is drawn around `foot`, not against an edge.
  public var isFloating = false
  /// A drag is going on or has just ended: a click must not do anything.
  public var blocksClicks = false
  /// The clickable part of the pill, in the coordinates of `PillView` (origin at the top left).
  /// Empty when nothing is shown.
  public private(set) var hotFrame = CGRect.zero
  /// What is showing can be picked up and moved (a message cannot).
  public private(set) var canMove = false
  /// A recording is showing: a shaky click on its buttons is still a click.
  public private(set) var isRecording = false

  public init() {}

  fileprivate func note(_ frame: CGRect) {
    if frame != hotFrame { hotFrame = frame }
  }

  fileprivate func note(_ state: PillState) {
    if state.canMove != canMove { canMove = state.canMove }
    if state.isRecording != isRecording { isRecording = state.isRecording }
  }
}

/// Where the pill is, handed up from the pill's parts to `PillView`.
private struct HotFrameKey: PreferenceKey {
  static let defaultValue = CGRect.zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if !next.isEmpty { value = value.isEmpty ? next : value.union(next) }
  }
}

/// The floating pill: a small capsule at an edge of the screen that shows
/// when Spaces is listening, working or has something to say.
///
/// Give it a transparent window. It draws the pill against the edge and at
/// the point its `PillPointer` names, and everything it shows opens inward
/// from there and stays inside the window. Reads `AppModel` and `MacControls`
/// from the environment.
public struct PillView: View {
  @Environment(AppModel.self) private var model
  @Environment(MacControls.self) private var controls
  private let pointer: PillPointer

  public init(pointer: PillPointer) {
    self.pointer = pointer
  }

  public var body: some View {
    let state = state
    PillBody(
      state: state,
      edge: pointer.edge,
      foot: pointer.foot,
      isFloating: pointer.isFloating,
      actions: actions
    )
    // The window needs the pill's place measured from its own corner.
    .coordinateSpace(name: PillBody.space)
    .backgroundPreferenceValue(HotFrameKey.self) { frame in
      // Passed on a turn later: this runs while the view is being laid out.
      let _ = DispatchQueue.main.async {
        pointer.note(frame)
        pointer.note(state)
      }
      SwiftUI.Color.clear
    }
    // Always the dark pill: it sits on other apps, not on our own window.
    .environment(\.colorScheme, .light)
  }

  private var state: PillState {
    let hidden = controls.pillHiddenUntil.map { $0 > Date() } ?? false
    return PillState.resolve(
      phase: model.dictation.phase,
      showsRecording: controls.showsRecording,
      isWrappingUp: controls.isWrappingUp,
      notice: controls.notice,
      meetingSince: model.meetings.live?.startedAt,
      isEnabled: model.settings.isOnboarded && model.settings.showPill && !hidden,
      isHovered: pointer.isHovered,
      hintKeys: model.settings.shortcut(for: .pushToTalk)?.keyCaps ?? [],
      // Asked only while the pointer is on the pill, which is when the hint shows.
      shortcutsPaused: pointer.isHovered && !pointer.isFloating && SecureInput.isOn,
      isGrabbed: pointer.isFloating
    )
  }

  /// What the buttons do. The release that ends a drag is not a click.
  private var actions: PillActions {
    func click(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
      { [pointer] in
        if !pointer.blocksClicks { action() }
      }
    }
    return PillActions(
      dictate: click { controls.toggleHandsFree() },
      stop: click { controls.finish() },
      cancel: click { controls.cancel() },
      tapNotice: click { controls.fixNotice() },
      dismissNotice: click { controls.dismissNotice() },
      stopMeeting: click { controls.toggleMeeting() },
      openMeeting: click {
        if let id = model.meetings.live?.meetingID { controls.open(.meeting(id)) }
      }
    )
  }
}

/// Sizes of the pill's parts, in points. "Length" runs along the screen edge the pill is
/// on and "thickness" runs away from it, so one set of numbers serves all four edges.
private enum PillMetrics {
  static let restingLength: CGFloat = 40
  static let restingThickness: CGFloat = 8
  static let hoverLength: CGFloat = 64
  static let hoverThickness: CGFloat = 30
  /// The thickness of the pill while it records or works, and of the meeting chip.
  static let thickness: CGFloat = 28
  static let workingLength: CGFloat = 52
  /// The longest bar of the waveform.
  static let wave: CGFloat = 16
  /// The room at each end of a recording pill that has no button there.
  static let endPadding: CGFloat = 10
  /// The room at an end that holds a round button.
  static let buttonPadding: CGFloat = Spaces.Space.xxs
  /// The round buttons: the circle that is drawn, and the larger area that takes the click.
  static let roundButton: CGFloat = 20
  static let roundButtonTarget = CGSize(width: 24, height: 28)
  /// Between the parts of a recording pill.
  static let partGap: CGFloat = Spaces.Space.xs
  /// Between the dot, the time and the button of the meeting chip.
  static let chipGap: CGFloat = 6
  static let noticeWidth: CGFloat = 340
  static let hintWidth: CGFloat = 280
  static let radius: CGFloat = 16
  static let dot: CGFloat = 8
  /// The gap between the pill and its screen edge, and between the pill and what opens from it.
  static let gap: CGFloat = Spaces.Space.xs
}

/// The pill drawn from a `PillState`, against one edge of the space it gets.
struct PillBody: View {
  static let space = "pill"

  let state: PillState
  var edge = PillEdge.bottom
  /// The point the pill is attached to, measured from this view's top left. `nil` is the middle of `edge`.
  var foot: CGPoint?
  /// Drawn around `foot` instead of against the edge, as while it is dragged.
  var isFloating = false
  /// A fixed loudness and clock for still pictures; `nil` follows the app.
  var previewLevel: Double?
  var previewNow: Date?
  var actions = PillActions()

  var body: some View {
    PillStage(edge: edge, foot: foot, isFloating: isFloating, gap: PillMetrics.gap) {
      group
      // Carried by the pointer, the pill says nothing: it is on its way somewhere.
      if case .hint(let keys) = state.look, !state.isGrabbed {
        PillHint(keys: keys, isPaused: state.shortcutsPaused)
          .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: edge.anchor)))
      }
    }
    .animation(Spaces.Motion.spring, value: state)
    .animation(Spaces.Motion.spring, value: edge)
  }

  /// The pill and, while a meeting is recorded, its chip: side by side on a flat edge, one
  /// under the other on a side edge.
  private var group: some View {
    let layout =
      edge.isSide
      ? AnyLayout(VStackLayout(alignment: edge == .left ? .leading : .trailing, spacing: PillMetrics.gap))
      : AnyLayout(HStackLayout(spacing: PillMetrics.gap))
    return layout {
      if state.look != .hidden {
        capsule.transition(.opacity)
      }
      if let since = state.meetingSince {
        MeetingChip(
          since: since,
          now: previewNow,
          isUpright: edge.isSide,
          open: actions.openMeeting,
          stop: actions.stopMeeting
        )
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
      }
    }
    .background {
      GeometryReader { proxy in
        SwiftUI.Color.clear.preference(
          key: HotFrameKey.self,
          value: state.isEmpty ? .zero : proxy.frame(in: .named(Self.space))
        )
      }
    }
  }

  private var capsule: some View {
    let shape = RoundedRectangle(cornerRadius: PillMetrics.radius, style: .continuous)
    return
      content
      .frame(width: size.width, height: size.height)
      .background(fill, in: shape)
      .overlay {
        shape.strokeBorder(Spaces.Color.onInverse.opacity(outline), lineWidth: Spaces.Stroke.hairline)
      }
      .clipShape(shape)
      .contentShape(shape)
  }

  /// A fixed size where the look has one; `nil` lets the content decide.
  private var size: (width: CGFloat?, height: CGFloat?) {
    switch state.look {
    case .hidden: (0, 0)
    case .resting: along(PillMetrics.restingLength, across: PillMetrics.restingThickness)
    case .hint: along(PillMetrics.hoverLength, across: PillMetrics.hoverThickness)
    case .recording: along(nil, across: PillMetrics.thickness)
    case .working: along(PillMetrics.workingLength, across: PillMetrics.thickness)
    case .notice, .question: (nil, nil)
    }
  }

  /// A size given as a length along the edge and a thickness away from it.
  private func along(_ length: CGFloat?, across thickness: CGFloat?) -> (width: CGFloat?, height: CGFloat?) {
    edge.isSide ? (thickness, length) : (length, thickness)
  }

  private var fill: SwiftUI.Color {
    switch state.look {
    case .resting: Spaces.Color.inverse.opacity(0.94)
    default: Spaces.Color.inverse
    }
  }

  /// The resting pill is tiny and sits on anything: near-black with a crisp light rim, so it
  /// reads on a dark window as well as on a light one.
  private var outline: Double {
    state.look == .resting ? 0.6 : 0.2
  }

  @ViewBuilder private var content: some View {
    switch state.look {
    case .hidden:
      EmptyView()
    case .resting:
      Button(action: actions.dictate) { SwiftUI.Color.clear }
        .buttonStyle(.plain)
        .accessibilityLabel("Start dictating")
        .accessibilityHint(Self.moveHint)
    case .hint:
      Button(action: actions.dictate) {
        Image(systemName: "mic.fill")
          .spacesText(.bodyStrong, color: Spaces.Color.onInverse)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Start dictating")
      .accessibilityHint(Self.moveHint)
    case .recording(let mode, let handsFree):
      recording(mode: mode, handsFree: handsFree)
    case .working:
      ProcessingIndicator(tint: Spaces.Color.onInverse, height: PillMetrics.wave, axis: barAxis)
    case .notice(let message, let canFix, let isProblem):
      notice(message, canFix: canFix, isProblem: isProblem)
    case .question(let message, let yes, let no):
      question(message, yes: yes, no: no)
    }
  }

  private static let moveHint = "You can drag the pill to any edge of the screen."

  /// The way the row of waveform bars runs: along the pill.
  private var barAxis: Axis { edge.isSide ? .vertical : .horizontal }

  /// Cancel, what is being recorded, the waveform and stop, in a row along the pill. Only
  /// hands-free has the buttons: push to talk ends when the key is let go.
  private func recording(mode: DictationMode, handsFree: Bool) -> some View {
    let layout =
      edge.isSide
      ? AnyLayout(VStackLayout(spacing: PillMetrics.partGap))
      : AnyLayout(HStackLayout(spacing: PillMetrics.partGap))
    let ends = handsFree ? PillMetrics.buttonPadding : PillMetrics.endPadding
    return layout {
      if handsFree {
        PillRoundButton(
          symbol: "xmark",
          label: "Cancel dictation",
          isUpright: edge.isSide,
          action: actions.cancel
        )
      }
      if mode == .command {
        commandMark
      }
      PillWaveform(level: previewLevel, axis: barAxis)
      if handsFree {
        PillRoundButton(
          symbol: "stop.fill",
          label: "Finish dictation",
          isRecordingRed: true,
          isUpright: edge.isSide,
          action: actions.stop
        )
      }
    }
    .padding(edge.isSide ? .vertical : .horizontal, ends)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(mode == .command ? "Listening for a command" : "Listening")
    .accessibilityHint(Self.moveHint)
  }

  /// Says "this is command mode": the word where there is room for it, a sign where the pill is upright.
  @ViewBuilder private var commandMark: some View {
    if edge.isSide {
      Image(systemName: "command")
        .spacesText(.captionStrong, color: Spaces.Color.onInverse)
        .accessibilityHidden(true)
    } else {
      Text("Command")
        .spacesText(.captionStrong, color: Spaces.Color.onInverse)
        .fixedSize()
    }
  }

  private func notice(_ message: String, canFix: Bool, isProblem: Bool) -> some View {
    Button(action: actions.tapNotice) {
      HStack(alignment: .center, spacing: Spaces.Space.s) {
        Image(systemName: isProblem ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
          .spacesText(.body, color: isProblem ? Spaces.Color.recording : Spaces.Color.onInverse)
          .accessibilityHidden(true)
        Text(message)
          .spacesText(.captionStrong, color: Spaces.Color.onInverse)
          .lineLimit(3)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Image(systemName: canFix ? "chevron.right" : "xmark")
          .spacesText(.caption, color: Spaces.Color.onInverse.opacity(0.6))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, Spaces.Space.l)
      .padding(.vertical, Spaces.Space.s + Spaces.Space.xxs)
      .frame(maxWidth: PillMetrics.noticeWidth)
      .fixedSize(horizontal: true, vertical: false)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint(canFix ? "Opens the place to fix this" : "Dismisses this message")
  }

  /// A message that asks something: the words, then the two answers.
  private func question(_ message: String, yes: String, no: String) -> some View {
    VStack(alignment: .trailing, spacing: Spaces.Space.s) {
      Text(message)
        .spacesText(.captionStrong, color: Spaces.Color.onInverse)
        .lineLimit(3)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: Spaces.Space.s) {
        PillAnswer(title: no, isMain: false, action: actions.dismissNotice)
        PillAnswer(title: yes, isMain: true, action: actions.tapNotice)
      }
    }
    .padding(.horizontal, Spaces.Space.l)
    .padding(.vertical, Spaces.Space.m)
    .frame(width: PillMetrics.noticeWidth)
    .accessibilityElement(children: .contain)
  }
}

extension PillEdge {
  /// The side of a view that faces this screen edge: what opens from the pill grows away from it.
  fileprivate var anchor: UnitPoint {
    switch self {
    case .bottom: .bottom
    case .top: .top
    case .left: .leading
    case .right: .trailing
    }
  }
}

/// Puts the pill against its edge and the hint beside it, further in.
///
/// The first view is the pill. It is attached to `foot`, centred on it along the edge, and
/// moved along the edge as far as needed to stay inside. The second view, when there is
/// one, sits on the inward side of the pill and is kept inside the same way. While
/// `isFloating`, the pill is simply centred on `foot` and nothing sits beside it.
private struct PillStage: Layout {
  let edge: PillEdge
  let foot: CGPoint?
  let isFloating: Bool
  let gap: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let pill = subviews.first else { return }
    let foot = foot.map { CGPoint(x: bounds.minX + $0.x, y: bounds.minY + $0.y) } ?? middle(of: bounds)
    let room = ProposedViewSize(width: bounds.width, height: bounds.height)
    let pillFrame = frame(of: pill.sizeThatFits(.unspecified), from: foot, offset: gap, in: bounds)
    pill.place(at: pillFrame.origin, anchor: .topLeading, proposal: room)
    guard subviews.count > 1 else { return }
    let depth = edge.isSide ? pillFrame.width : pillFrame.height
    let hintFrame = frame(
      of: subviews[1].sizeThatFits(.unspecified),
      from: foot,
      offset: gap + depth + gap,
      in: bounds.insetBy(dx: gap, dy: gap)
    )
    subviews[1].place(at: hintFrame.origin, anchor: .topLeading, proposal: room)
  }

  private func middle(of bounds: CGRect) -> CGPoint {
    switch edge {
    case .bottom: CGPoint(x: bounds.midX, y: bounds.maxY)
    case .top: CGPoint(x: bounds.midX, y: bounds.minY)
    case .left: CGPoint(x: bounds.minX, y: bounds.midY)
    case .right: CGPoint(x: bounds.maxX, y: bounds.midY)
    }
  }

  /// Where a view of `size` goes: `offset` inward from `foot`, centred on it along the edge.
  private func frame(of size: CGSize, from foot: CGPoint, offset: CGFloat, in bounds: CGRect) -> CGRect {
    var origin = CGPoint(x: foot.x - size.width / 2, y: foot.y - size.height / 2)
    guard !isFloating else { return CGRect(origin: origin, size: size) }
    switch edge {
    case .bottom: origin.y = foot.y - offset - size.height
    case .top: origin.y = foot.y + offset
    case .left: origin.x = foot.x + offset
    case .right: origin.x = foot.x - offset - size.width
    }
    if edge.isSide {
      origin.y = Self.fit(origin.y, length: size.height, into: bounds.minY, bounds.height)
    } else {
      origin.x = Self.fit(origin.x, length: size.width, into: bounds.minX, bounds.width)
    }
    return CGRect(origin: origin, size: size)
  }

  private static func fit(_ value: CGFloat, length: CGFloat, into start: CGFloat, _ room: CGFloat) -> CGFloat
  {
    guard length <= room else { return start + (room - length) / 2 }
    return min(max(value, start), start + room - length)
  }
}

/// The waveform on the pill. Reads the loudness itself, so only it redraws 20 times a second.
private struct PillWaveform: View {
  @Environment(AppModel.self) private var model
  let level: Double?
  let axis: Axis

  var body: some View {
    Waveform(
      level: level ?? Double(model.dictation.level),
      bars: 11,
      tint: Spaces.Color.onInverse,
      height: PillMetrics.wave,
      axis: axis
    )
  }
}

/// The bubble beside the hovered pill that says how to dictate.
private struct PillHint: View {
  let keys: [String]
  var isPaused = false

  var body: some View {
    text
      .spacesText(.caption, color: Spaces.Color.onInverse)
      .multilineTextAlignment(.center)
      // The long hint takes two lines instead of running out of the pill's window.
      .fixedSize(horizontal: !isLong, vertical: true)
      .frame(width: isLong ? PillMetrics.hintWidth : nil)
      .padding(.horizontal, Spaces.Space.m)
      .padding(.vertical, Spaces.Space.s)
      .background(Spaces.Color.inverse, in: shape)
      .overlay {
        shape.strokeBorder(Spaces.Color.onInverse.opacity(0.2), lineWidth: Spaces.Stroke.hairline)
      }
      .accessibilityHidden(true)
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: PillMetrics.radius, style: .continuous)
  }

  private var isLong: Bool { isPaused && !keys.isEmpty }

  private var text: Text {
    // While a password field has the keyboard, macOS keeps every key press from other apps.
    if isLong { return Text("Shortcuts are off while a password field is in use. Click to dictate") }
    guard !keys.isEmpty else { return Text("Click to dictate") }
    return Text("Hold ") + Text(keys.joined(separator: " ")).bold() + Text(" to dictate, or click")
  }
}

/// A small round button on the dark pill. The circle is small; the area that takes the
/// click is the full thickness of the pill.
private struct PillRoundButton: View {
  let symbol: String
  let label: String
  var isRecordingRed = false
  /// The pill stands upright, so the click area is wide instead of tall.
  var isUpright = false
  let action: @MainActor () -> Void

  var body: some View {
    let target = PillMetrics.roundButtonTarget
    Button(action: action) {
      Image(systemName: symbol)
        .spacesText(.caption, color: Spaces.Color.onInverse)
        .imageScale(.small)
        .frame(width: PillMetrics.roundButton, height: PillMetrics.roundButton)
        .background(
          isRecordingRed ? Spaces.Color.recording : Spaces.Color.onInverse.opacity(0.16),
          in: Circle()
        )
        .frame(
          width: isUpright ? target.height : target.width,
          height: isUpright ? target.width : target.height
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }
}

/// One of the two answers under a question on the pill.
private struct PillAnswer: View {
  let title: String
  let isMain: Bool
  let action: @MainActor () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .spacesText(.captionStrong, color: isMain ? Spaces.Color.inverse : Spaces.Color.onInverse)
        .fixedSize()
        .padding(.horizontal, Spaces.Space.m)
        .frame(height: Spaces.Space.xl)
        .background(isMain ? Spaces.Color.onInverse : Spaces.Color.onInverse.opacity(0.16), in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

/// The red dot and timer of a meeting recording, with a stop button: in a row, or stacked
/// (dot, time, stop) beside an upright pill. The time is always written level.
private struct MeetingChip: View {
  let since: Date
  let now: Date?
  var isUpright = false
  let open: @MainActor () -> Void
  let stop: @MainActor () -> Void

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: PillMetrics.thickness / 2, style: .continuous)
    let layout =
      isUpright
      ? AnyLayout(VStackLayout(spacing: Spaces.Space.xxs))
      : AnyLayout(HStackLayout(spacing: PillMetrics.chipGap))
    layout {
      Button(action: open) {
        layout {
          Circle()
            .fill(Spaces.Color.recording)
            .frame(width: PillMetrics.dot, height: PillMetrics.dot)
          clock
        }
        .frame(maxWidth: isUpright ? .infinity : nil, maxHeight: isUpright ? nil : .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open this meeting")
      .accessibilityLabel("Recording a meeting. Open it.")
      PillRoundButton(
        symbol: "stop.fill",
        label: "Stop the meeting recording",
        isUpright: isUpright,
        action: stop
      )
    }
    .padding(.leading, isUpright ? PillMetrics.chipGap : Spaces.Space.m - Spaces.Space.xxs)
    .padding(.trailing, isUpright ? PillMetrics.chipGap : PillMetrics.buttonPadding)
    .padding(.top, isUpright ? Spaces.Space.s : 0)
    .padding(.bottom, isUpright ? PillMetrics.buttonPadding : 0)
    .frame(height: isUpright ? nil : PillMetrics.thickness)
    .fixedSize(horizontal: isUpright, vertical: false)
    .background(Spaces.Color.inverse, in: shape)
    .overlay {
      shape.strokeBorder(Spaces.Color.onInverse.opacity(0.2), lineWidth: Spaces.Stroke.hairline)
    }
  }

  @ViewBuilder private var clock: some View {
    if let now {
      label(at: now)
    } else {
      TimelineView(.periodic(from: since, by: 1)) { timeline in label(at: timeline.date) }
    }
  }

  private func label(at date: Date) -> some View {
    Text(Self.elapsed(from: since, to: date))
      .spacesText(.captionStrong, color: Spaces.Color.onInverse)
      .monospacedDigit()
      .fixedSize()
  }

  /// "4:07", or "1:02:09" from an hour on.
  static func elapsed(from start: Date, to end: Date) -> String {
    let total = max(0, Int(end.timeIntervalSince(start)))
    let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
      : String(format: "%d:%02d", minutes, seconds)
  }
}
