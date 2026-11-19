import Observation
import SwiftUI
import WisperDomain
import WisperEngine
import WisperMac
import WisperUI

/// What the pill's window tells the pill, and the pill tells its window.
///
/// The pill lives in a window that never takes focus and lets clicks through,
/// so the window watches the pointer itself: it sets `isHovered`, and reads
/// `hotFrame` to know where the pill can be clicked.
@MainActor
@Observable
public final class PillPointer {
  /// The pointer is over the pill.
  public var isHovered = false
  /// The clickable part of the pill, in the coordinates of `PillView` (origin at the top left).
  /// Empty when nothing is shown.
  public private(set) var hotFrame = CGRect.zero

  public init() {}

  fileprivate func note(_ frame: CGRect) {
    if frame != hotFrame { hotFrame = frame }
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

/// The floating pill: a small capsule at the bottom of the screen that shows
/// when Open Wisper is listening, working or has something to say.
///
/// Give it a transparent window; it sits at the bottom centre of the space it
/// gets. Reads `AppModel` and `MacControls` from the environment.
public struct PillView: View {
  @Environment(AppModel.self) private var model
  @Environment(MacControls.self) private var controls
  private let pointer: PillPointer

  public init(pointer: PillPointer) {
    self.pointer = pointer
  }

  public var body: some View {
    PillBody(state: state, actions: actions)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      // The window needs the pill's place measured from its own corner.
      .coordinateSpace(name: PillBody.space)
      .backgroundPreferenceValue(HotFrameKey.self) { frame in
        // Passed on a turn later: this runs while the view is being laid out.
        let _ = DispatchQueue.main.async { pointer.note(frame) }
        SwiftUI.Color.clear
      }
      // Always the dark pill: it sits on other apps, not on our own window.
      .environment(\.colorScheme, .light)
      .environment(\.wisperIdiom, .mac)
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
      shortcutsPaused: pointer.isHovered && SecureInput.isOn
    )
  }

  private var actions: PillActions {
    PillActions(
      dictate: { controls.toggleHandsFree() },
      stop: { controls.finish() },
      cancel: { controls.cancel() },
      tapNotice: { controls.fixNotice() },
      startMeeting: { controls.toggleMeeting() },
      stopMeeting: { controls.toggleMeeting() },
      openMeeting: {
        if let id = model.meetings.live?.meetingID { controls.open(.meeting(id)) }
      }
    )
  }
}

/// Sizes of the pill's parts, in points.
private enum PillMetrics {
  static let resting = CGSize(width: 40, height: 8)
  static let hover = CGSize(width: 50, height: 30)
  static let height: CGFloat = 32
  static let holdWidth: CGFloat = 92
  static let workingWidth: CGFloat = 64
  static let noticeWidth: CGFloat = 340
  static let hintWidth: CGFloat = 280
  static let radius: CGFloat = 16
  static let roundButton: CGFloat = 24
  static let waveHeight: CGFloat = 16
  static let dot: CGFloat = 8
}

/// The pill drawn from a `PillState`.
struct PillBody: View {
  static let space = "pill"

  let state: PillState
  /// A fixed loudness and clock for still pictures; `nil` follows the app.
  var previewLevel: Double?
  var previewNow: Date?
  var actions = PillActions()

  var body: some View {
    VStack(spacing: Wisper.Space.xs) {
      if case .hint(let keys) = state.look {
        PillHint(keys: keys, isPaused: state.shortcutsPaused)
          .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
      }
      HStack(spacing: Wisper.Space.xs) {
        if state.look != .hidden {
          capsule.transition(.opacity)
        }
        if case .hint = state.look, state.meetingSince == nil {
          PillRoundButton(
            symbol: "record.circle",
            label: "Start a meeting recording",
            size: PillMetrics.hover.height
          ) {
            actions.startMeeting()
          }
          .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
        if let since = state.meetingSince {
          MeetingChip(since: since, now: previewNow, open: actions.openMeeting, stop: actions.stopMeeting)
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
    .padding(.bottom, Wisper.Space.xs)
    .animation(Wisper.Motion.spring, value: state)
  }

  private var capsule: some View {
    let shape = RoundedRectangle(cornerRadius: PillMetrics.radius, style: .continuous)
    return
      content
      .frame(width: size.width, height: size.height)
      .background(fill, in: shape)
      .overlay {
        shape.strokeBorder(Wisper.Color.onInverse.opacity(outline), lineWidth: Wisper.Stroke.hairline)
      }
      .clipShape(shape)
      .contentShape(shape)
  }

  /// A fixed size where the look has one; `nil` lets the content decide.
  private var size: (width: CGFloat?, height: CGFloat?) {
    switch state.look {
    case .hidden: (0, 0)
    case .resting: (PillMetrics.resting.width, PillMetrics.resting.height)
    case .hint: (PillMetrics.hover.width, PillMetrics.hover.height)
    case .recording(.dictation, false): (PillMetrics.holdWidth, PillMetrics.height)
    case .recording: (nil, PillMetrics.height)
    case .working: (PillMetrics.workingWidth, PillMetrics.height)
    case .notice: (nil, nil)
    }
  }

  private var fill: SwiftUI.Color {
    switch state.look {
    case .resting: Wisper.Color.inverse.opacity(0.94)
    case .recording(.command, _): Wisper.Color.accent
    default: Wisper.Color.inverse
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
    case .hint:
      Button(action: actions.dictate) {
        Image(systemName: "mic.fill")
          .wisperText(.bodyStrong, color: Wisper.Color.onInverse)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Start dictating")
    case .recording(let mode, let handsFree):
      recording(mode: mode, handsFree: handsFree)
    case .working:
      ProcessingIndicator(tint: Wisper.Color.onInverse, height: PillMetrics.waveHeight)
    case .notice(let message, let canFix, let isProblem):
      notice(message, canFix: canFix, isProblem: isProblem)
    }
  }

  private func recording(mode: DictationMode, handsFree: Bool) -> some View {
    HStack(spacing: Wisper.Space.s) {
      if handsFree {
        PillRoundButton(symbol: "xmark", label: "Cancel dictation", action: actions.cancel)
      }
      if mode == .command {
        Text("Command")
          .wisperText(.captionStrong, color: Wisper.Color.onInverse)
          .fixedSize()
      }
      PillWaveform(level: previewLevel)
      if handsFree {
        PillRoundButton(
          symbol: "stop.fill",
          label: "Finish dictation",
          isRecordingRed: true,
          action: actions.stop
        )
      }
    }
    .padding(.horizontal, handsFree ? Wisper.Space.xs : Wisper.Space.l)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(mode == .command ? "Listening for a command" : "Listening")
  }

  private func notice(_ message: String, canFix: Bool, isProblem: Bool) -> some View {
    Button(action: actions.tapNotice) {
      HStack(alignment: .center, spacing: Wisper.Space.s) {
        Image(systemName: isProblem ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
          .wisperText(.body, color: isProblem ? Wisper.Color.recording : Wisper.Color.onInverse)
          .accessibilityHidden(true)
        Text(message)
          .wisperText(.captionStrong, color: Wisper.Color.onInverse)
          .lineLimit(3)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Image(systemName: canFix ? "chevron.right" : "xmark")
          .wisperText(.caption, color: Wisper.Color.onInverse.opacity(0.6))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, Wisper.Space.l)
      .padding(.vertical, Wisper.Space.s + Wisper.Space.xxs)
      .frame(maxWidth: PillMetrics.noticeWidth)
      .fixedSize(horizontal: true, vertical: false)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint(canFix ? "Opens the place to fix this" : "Dismisses this message")
  }
}

/// The waveform on the pill. Reads the loudness itself, so only it redraws 20 times a second.
private struct PillWaveform: View {
  @Environment(AppModel.self) private var model
  let level: Double?

  var body: some View {
    Waveform(
      level: level ?? Double(model.dictation.level),
      bars: 11,
      tint: Wisper.Color.onInverse,
      height: PillMetrics.waveHeight
    )
  }
}

/// The bubble above the hovered pill that says how to dictate.
private struct PillHint: View {
  let keys: [String]
  var isPaused = false

  var body: some View {
    text
      .wisperText(.caption, color: Wisper.Color.onInverse)
      .multilineTextAlignment(.center)
      // The long hint takes two lines instead of running out of the pill's window.
      .fixedSize(horizontal: !isLong, vertical: true)
      .frame(width: isLong ? PillMetrics.hintWidth : nil)
      .padding(.horizontal, Wisper.Space.m)
      .padding(.vertical, Wisper.Space.s)
      .background(Wisper.Color.inverse, in: shape)
      .overlay {
        shape.strokeBorder(Wisper.Color.onInverse.opacity(0.2), lineWidth: Wisper.Stroke.hairline)
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

/// A small round button on the dark pill.
private struct PillRoundButton: View {
  let symbol: String
  let label: String
  var size = PillMetrics.roundButton
  var isRecordingRed = false
  let action: @MainActor () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .wisperText(size > PillMetrics.roundButton ? .bodyStrong : .caption, color: Wisper.Color.onInverse)
        .frame(width: size, height: size)
        .background(background, in: Circle())
        .overlay {
          if size > PillMetrics.roundButton {
            Circle().strokeBorder(Wisper.Color.onInverse.opacity(0.2), lineWidth: Wisper.Stroke.hairline)
          }
        }
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }

  private var background: SwiftUI.Color {
    if isRecordingRed { return Wisper.Color.recording }
    return size > PillMetrics.roundButton ? Wisper.Color.inverse : Wisper.Color.onInverse.opacity(0.16)
  }
}

/// The red dot and timer of a meeting recording, with a stop button.
private struct MeetingChip: View {
  let since: Date
  let now: Date?
  let open: @MainActor () -> Void
  let stop: @MainActor () -> Void

  var body: some View {
    HStack(spacing: Wisper.Space.s) {
      Button(action: open) {
        HStack(spacing: Wisper.Space.s) {
          Circle()
            .fill(Wisper.Color.recording)
            .frame(width: PillMetrics.dot, height: PillMetrics.dot)
          clock
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open this meeting")
      .accessibilityLabel("Recording a meeting. Open it.")
      PillRoundButton(symbol: "stop.fill", label: "Stop the meeting recording", action: stop)
    }
    .padding(.leading, Wisper.Space.m)
    .padding(.trailing, Wisper.Space.xs)
    .frame(height: PillMetrics.height)
    .background(Wisper.Color.inverse, in: Capsule())
    .overlay {
      Capsule().strokeBorder(Wisper.Color.onInverse.opacity(0.2), lineWidth: Wisper.Stroke.hairline)
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
      .wisperText(.captionStrong, color: Wisper.Color.onInverse)
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
