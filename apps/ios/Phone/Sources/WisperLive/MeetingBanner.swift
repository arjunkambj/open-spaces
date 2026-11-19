import SwiftUI
import WisperDomain
import WisperUI

// The pieces a recording is drawn with outside the app: on the Lock Screen and in the
// Dynamic Island. Plain SwiftUI, so they can be drawn on a Mac too.

/// The Lock Screen banner: what is being recorded, for how long, and a way to stop it.
///
/// `stop` is the control that stops the recording. On the Lock Screen it is a button that
/// runs an App Intent in the app; give it a `StopLabel` to look right.
public struct MeetingBanner<Stop: View>: View {
  private let title: String
  private let startedAt: Date
  private let stop: Stop

  public init(title: String, startedAt: Date, @ViewBuilder stop: () -> Stop) {
    self.title = title
    self.startedAt = startedAt
    self.stop = stop()
  }

  public var body: some View {
    HStack(spacing: Wisper.Space.m) {
      RecordingMark(size: 40)
      VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
        Text(title)
          .wisperText(.bodyStrong)
          .lineLimit(1)
        HStack(spacing: Wisper.Space.xs) {
          Text("Recording")
          MeetingClock(startedAt: startedAt)
        }
        .wisperText(.caption)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      stop
    }
    .padding(Wisper.Space.l)
    .environment(\.wisperIdiom, .phone)
  }
}

/// The red dot with the Open Wisper mark: "this is recording".
public struct RecordingMark: View {
  private let size: CGFloat

  public init(size: CGFloat) {
    self.size = size
  }

  public var body: some View {
    WisperGlyph(size: size * 0.45, tint: .white)
      .frame(width: size, height: size)
      .background(Wisper.Color.recording, in: Circle())
      .accessibilityLabel("Open Wisper is recording")
  }
}

/// The time since the recording began, counting up by itself.
public struct MeetingClock: View {
  private let startedAt: Date

  public init(startedAt: Date) {
    self.startedAt = startedAt
  }

  public var body: some View {
    Text(startedAt, style: .timer)
      .monospacedDigit()
      .accessibilityLabel("Recording time")
  }
}

/// The face of the Stop button on the Lock Screen and in the Dynamic Island.
public struct StopLabel: View {
  public init() {}

  public var body: some View {
    Label("Stop", systemImage: "stop.fill")
      .wisperText(.captionStrong, color: .white)
      .padding(.horizontal, Wisper.Space.m)
      .padding(.vertical, Wisper.Space.s)
      .background(Wisper.Color.recording, in: Capsule())
      .accessibilityLabel("Stop recording")
  }
}
