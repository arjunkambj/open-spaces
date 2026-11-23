import SpacesDomain
import SwiftUI

/// What a history row can do. The screen supplies the actions.
struct HomeRowActions {
  var copy: () -> Void
  var togglePlayback: () -> Void
  var retry: () -> Void
  var delete: () -> Void
}

/// One dictation in the history list: when, the text, where it went, and its actions.
///
/// The actions show while the pointer is over the row or one of them has keyboard focus.
/// The context menu has them too.
struct HomeDictationRow: View {
  let dictation: Dictation
  let player: HomeAudioPlayer
  let isRetrying: Bool
  /// False while the app is recording or making text, when a retry cannot start.
  let canRetry: Bool
  let actions: HomeRowActions

  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false
  @State private var isExpanded = false
  @State private var shownHeight: CGFloat = 0
  @State private var fullHeight: CGFloat = 0
  @FocusState private var focusedAction: Action?

  private enum Action: Hashable {
    case play, copy, delete
  }

  /// The width kept free at the end of a row for the app name and the actions.
  private static let gutter: CGFloat = 84
  private static let timeWidth: CGFloat = 64
  /// The heights of the kit's own rows.
  private static let rowHeight: CGFloat = 46
  private static let rowPadding: CGFloat = 12
  /// The side of a small icon button.
  private static let actionSide: CGFloat = 26
  private static let indicatorHeight: CGFloat = 14
  /// The height of the small Retry button, so the row does not jump while it retries.
  private static let retryHeight: CGFloat = 28

  private var hasAudio: Bool { dictation.audioFile != nil }
  private var isPlaying: Bool { player.playingID == dictation.id }
  private var showsActions: Bool { isHovered || simulatedHover || focusedAction != nil }
  private var time: String { HomeHistory.time(dictation.createdAt) }

  var body: some View {
    row
      .contentShape(Rectangle())
      .contextMenu { menuItems }
      .accessibilityElement(children: .contain)
  }

  // MARK: - Layout

  private var row: some View {
    HStack(alignment: .top, spacing: Spaces.Space.m) {
      Text(time)
        .spacesText(.caption, color: Spaces.Color.textTertiary)
        .lineLimit(1)
        .padding(.top, Spaces.Space.xxs)
        .frame(width: Self.timeWidth, alignment: .leading)
      content
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(dictation.appName ?? "")
        .spacesText(.caption, color: Spaces.Color.textTertiary)
        .lineLimit(1)
        .padding(.top, Spaces.Space.xxs)
        .frame(width: Self.gutter, alignment: .trailing)
        .opacity(showsActions ? 0 : 1)
        .accessibilityLabel(dictation.appName.map { "In \($0)" } ?? "")
    }
    .padding(.vertical, Self.rowPadding)
    .frame(minHeight: Self.rowHeight, alignment: .top)
    .overlay(alignment: .topTrailing) {
      HStack(spacing: Spaces.Space.xxs) {
        // While it plays, the stop button is beside the progress bar.
        if hasAudio && !isPlaying {
          IconButton("play", label: "Play recording", size: .small, action: actions.togglePlayback)
            .focused($focusedAction, equals: .play)
        }
        if !dictation.failed {
          IconButton("doc.on.doc", label: "Copy", size: .small, action: actions.copy)
            .focused($focusedAction, equals: .copy)
        }
        IconButton("trash", label: "Delete", size: .small, action: actions.delete)
          .focused($focusedAction, equals: .delete)
      }
      // Small buttons, so three of them fit in the gutter and the text keeps its width.
      .padding(.top, (Self.rowHeight - Self.actionSide) / 2)
      .padding(.trailing, -Spaces.Space.xs)
      .opacity(showsActions ? 1 : 0)
    }
    .rowChrome(isHighlighted: showsActions)
    .onHover { isHovered = $0 }
    .animation(Spaces.Motion.quick, value: showsActions)
  }

  @ViewBuilder private var menuItems: some View {
    if !dictation.failed {
      Button(action: actions.copy) { Label("Copy", systemImage: "doc.on.doc") }
    }
    if hasAudio {
      Button(action: actions.togglePlayback) {
        Label(isPlaying ? "Stop" : "Play recording", systemImage: isPlaying ? "stop.fill" : "play")
      }
    }
    if dictation.failed && hasAudio {
      Button(action: actions.retry) { Label("Retry", systemImage: "arrow.clockwise") }
        .disabled(isRetrying || !canRetry)
    }
    Divider()
    Button(role: .destructive, action: actions.delete) { Label("Delete", systemImage: "trash") }
  }

  // MARK: - Content

  private var content: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.s) {
      if let failure = dictation.failure {
        failed(failure)
      } else {
        text
      }
      if dictation.mode == .command {
        HStack(spacing: Spaces.Space.s) {
          Badge("Command", tone: .accent)
          if !dictation.failed, !dictation.rawText.isEmpty {
            Text("You said: “\(dictation.rawText)”")
              .spacesText(.caption)
              .lineLimit(1)
          }
        }
      }
      if isPlaying {
        HStack(spacing: Spaces.Space.s) {
          IconButton("stop.fill", label: "Stop", size: .small, action: actions.togglePlayback)
          ProgressBar(value: player.progress)
          Text("\(HomeHistory.clock(player.elapsed)) / \(HomeHistory.clock(dictation.duration))")
            .spacesText(.caption, color: Spaces.Color.textTertiary)
            .monospacedDigit()
            .fixedSize()
            .accessibilityLabel("Playing the recording")
        }
        .padding(.leading, -Spaces.Space.xs)
      }
    }
  }

  private var text: some View {
    let lines = 3
    let measures = HomeHistory.mayNeedCutting(dictation.text)
    let isCut = fullHeight > shownHeight + 1
    return VStack(alignment: .leading, spacing: Spaces.Space.xs) {
      Text(dictation.text)
        .spacesText(.body)
        .lineLimit(isExpanded ? nil : lines)
        .fixedSize(horizontal: false, vertical: true)
        .background {
          // The same text at full height, unseen, to learn whether lines were cut.
          if measures && !isExpanded {
            Text(dictation.text)
              .spacesText(.body)
              .fixedSize(horizontal: false, vertical: true)
              .hidden()
              .accessibilityHidden(true)
              .onGeometryChange(for: CGFloat.self) {
                $0.size.height
              } action: {
                fullHeight = $0
              }
          }
        }
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: { height in
          if !isExpanded { shownHeight = height }
        }
      if measures && (isCut || isExpanded) {
        Button(isExpanded ? "Show less" : "Show more") {
          withAnimation(Spaces.Motion.smooth) { isExpanded.toggle() }
        }
        .buttonStyle(.plain)
        .spacesText(.captionStrong, color: Spaces.Color.accent)
        .contentShape(Rectangle())
      }
    }
  }

  private func failed(_ failure: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spaces.Space.s) {
      Image(systemName: "exclamationmark.circle.fill")
        .spacesText(.caption, color: Spaces.Color.danger)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Spaces.Space.s) {
        VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
          Text("This one was not turned into text").spacesText(.bodyStrong)
          Text(failure)
            .spacesText(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        if isRetrying {
          HStack(spacing: Spaces.Space.s) {
            ProcessingIndicator(tint: Spaces.Color.textSecondary, height: Self.indicatorHeight)
            Text("Trying again…").spacesText(.caption)
          }
          .frame(minHeight: Self.retryHeight)
        } else if hasAudio {
          HStack(spacing: Spaces.Space.m) {
            Button("Retry", action: actions.retry)
              .buttonStyle(.spaces(.tertiary, size: .small))
              .disabled(!canRetry)
            Text("Your recording is saved.").spacesText(.caption)
          }
        } else {
          Text("The recording was not kept, so it cannot be tried again.")
            .spacesText(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
