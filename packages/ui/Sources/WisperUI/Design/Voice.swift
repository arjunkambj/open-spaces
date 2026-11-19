import SwiftUI

/// Bars that move with the loudness of a voice.
///
///     Waveform(level: Double(model.dictation.level))
///
/// Give it the latest level and it does the rest: the bars ripple, ease towards the level
/// and rest as small dots in silence. With Reduce Motion on, they only change height.
public struct Waveform: View {
  private let level: Double
  private let bars: Int
  private let tint: SwiftUI.Color
  private let height: CGFloat

  @State private var smoothed = Smoother()

  /// - level: loudness from 0 (silence) to 1.
  /// - bars: how many bars to draw.
  /// - height: the height of the tallest bar, in points.
  public init(level: Double, bars: Int = 9, tint: SwiftUI.Color = Wisper.Color.textPrimary, height: CGFloat = 20) {
    self.level = min(max(level, 0), 1)
    self.bars = max(bars, 1)
    self.tint = tint
    self.height = height
  }

  public var body: some View {
    let barWidth = max(2, height / 7)
    TimelineView(.animation(paused: Wisper.Motion.reduceMotion)) { timeline in
      let time = timeline.date.timeIntervalSinceReferenceDate
      let value = smoothed.value(target: level, at: time)
      HStack(spacing: barWidth * 0.8) {
        ForEach(0..<bars, id: \.self) { index in
          Capsule()
            .fill(tint)
            .frame(width: barWidth, height: Self.barHeight(index, of: bars, level: value, time: time, max: height))
        }
      }
      .frame(height: height)
    }
    .accessibilityHidden(true)
  }

  /// The height of one bar: taller in the middle, each bar on its own slow wave.
  nonisolated static func barHeight(_ index: Int, of count: Int, level: Double, time: Double, max height: CGFloat) -> CGFloat {
    let rest = Swift.max(2, height / 7)
    let position = count > 1 ? Double(index) / Double(count - 1) : 0.5
    let envelope = 0.45 + 0.55 * sin(position * .pi)
    let seed = Double(index) * 1.7
    let wave = 0.6 + 0.4 * sin(time * 7.3 + seed) * cos(time * 3.1 + seed * 0.6)
    let amount = Swift.min(1, pow(level, 0.6) * envelope * wave * 1.5)
    return rest + (height - rest) * amount
  }

  /// Follows the level quickly when it rises and slowly when it falls, like a meter needle.
  private final class Smoother {
    private var current = 0.0
    private var last: Double?

    func value(target: Double, at time: Double) -> Double {
      guard let last else {
        self.last = time
        current = target
        return current
      }
      let elapsed = Swift.min(Swift.max(time - last, 0), 0.1)
      self.last = time
      let rate = target > current ? 18.0 : 6.0
      current += (target - current) * Swift.min(1, elapsed * rate)
      return current
    }
  }
}

/// The "working on it" look of the waveform: the same bars, pulsing in a row.
/// Shown while speech is being turned into text.
public struct ProcessingIndicator: View {
  private let bars: Int
  private let tint: SwiftUI.Color
  private let height: CGFloat

  public init(bars: Int = 5, tint: SwiftUI.Color = Wisper.Color.textPrimary, height: CGFloat = 20) {
    self.bars = max(bars, 1)
    self.tint = tint
    self.height = height
  }

  public var body: some View {
    let barWidth = max(2, height / 7)
    TimelineView(.animation(paused: Wisper.Motion.reduceMotion)) { timeline in
      let time = timeline.date.timeIntervalSinceReferenceDate
      HStack(spacing: barWidth * 0.8) {
        ForEach(0..<bars, id: \.self) { index in
          let phase = time * 4.2 - Double(index) * 0.55
          let amount = 0.5 + 0.5 * sin(phase)
          Capsule()
            .fill(tint)
            .frame(width: barWidth, height: barWidth + (height * 0.62 - barWidth) * amount)
            .opacity(0.45 + 0.55 * amount)
        }
      }
      .frame(height: height)
    }
    .accessibilityLabel("Working")
  }
}

/// The big round button that starts and stops a recording.
///
///     RecordButton(.recording(level: level)) { toggle() }
public struct RecordButton: View {
  public enum Mode: Sendable, Equatable {
    /// Ready: a microphone.
    case idle
    /// Recording: live bars and a halo that grows with the voice.
    case recording(level: Double)
    /// Turning speech into text. The button does nothing in this mode.
    case processing
  }

  private let mode: Mode
  private let diameter: CGFloat
  private let action: () -> Void

  /// - diameter: 72 suits a toolbar or card, 96 the main control of an iPhone screen.
  public init(_ mode: Mode, diameter: CGFloat = 80, action: @escaping () -> Void) {
    self.mode = mode
    self.diameter = diameter
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(Wisper.Color.recording.opacity(0.16))
          .scaleEffect(haloScale)
          .animation(Wisper.Motion.smooth, value: haloScale)
        Circle()
          .fill(fill)
        glyph
      }
      .frame(width: diameter, height: diameter)
      .padding(diameter * 0.2)
      .contentShape(Circle())
    }
    .buttonStyle(RecordPressStyle())
    .disabled(mode == .processing)
    .animation(Wisper.Motion.spring, value: isRecording)
    .accessibilityLabel(accessibilityLabel)
  }

  private var isRecording: Bool {
    if case .recording = mode { return true }
    return false
  }

  private var haloScale: CGFloat {
    if case .recording(let level) = mode { return 1.12 + 0.28 * min(max(level, 0), 1) }
    return 1
  }

  private var fill: SwiftUI.Color {
    isRecording ? Wisper.Color.recording : Wisper.Color.inverse
  }

  @ViewBuilder private var glyph: some View {
    switch mode {
    case .idle:
      Image(systemName: "mic.fill")
        .font(.system(size: diameter * 0.34, weight: .medium))
        .foregroundStyle(Wisper.Color.onInverse)
    case .recording(let level):
      Waveform(level: level, bars: 5, tint: .white, height: diameter * 0.36)
    case .processing:
      ProcessingIndicator(tint: Wisper.Color.onInverse, height: diameter * 0.3)
    }
  }

  private var accessibilityLabel: String {
    switch mode {
    case .idle: "Start recording"
    case .recording: "Stop recording"
    case .processing: "Working"
    }
  }
}

private struct RecordPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
      .animation(Wisper.Motion.quick, value: configuration.isPressed)
  }
}
