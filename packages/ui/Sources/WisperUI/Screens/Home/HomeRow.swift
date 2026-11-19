import SwiftUI
import WisperDomain

/// What a history row can do. The screen supplies the actions.
struct HomeRowActions {
  var copy: () -> Void
  var togglePlayback: () -> Void
  var retry: () -> Void
  var delete: () -> Void
}

/// One dictation in the history list: when, the text, where it went, and its actions.
///
/// On a Mac the actions show while the pointer is over the row or one of them has keyboard
/// focus. On iPhone they are in the "…" menu. Both have them in the context menu too.
struct HomeDictationRow: View {
  let dictation: Dictation
  let player: HomeAudioPlayer
  let isRetrying: Bool
  /// False while the app is recording or making text, when a retry cannot start.
  let canRetry: Bool
  let actions: HomeRowActions

  @Environment(\.wisperIdiom) private var idiom
  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false
  @State private var isExpanded = false
  @State private var shownHeight: CGFloat = 0
  @State private var fullHeight: CGFloat = 0
  @FocusState private var focusedAction: Action?

  private enum Action: Hashable {
    case play, copy, delete
  }

  /// The width kept free at the end of a Mac row for the app name and the actions.
  private static let gutter: CGFloat = 84
  private static let timeWidth: CGFloat = 64
  /// The heights of the kit's own rows.
  private static let macRowHeight: CGFloat = 46
  private static let macRowPadding: CGFloat = 12
  /// The side of a small icon button on a Mac.
  private static let actionSide: CGFloat = 26
  private static let phoneRowHeight: CGFloat = 56
  private static let touchHeight: CGFloat = 32
  private static let indicatorHeight: CGFloat = 14
  /// The height of the small Retry button, so the row does not jump while it retries.
  private static let retryHeight: CGFloat = 28

  private var hasAudio: Bool { dictation.audioFile != nil }
  private var isPlaying: Bool { player.playingID == dictation.id }
  private var showsActions: Bool { isHovered || simulatedHover || focusedAction != nil }
  private var time: String { HomeHistory.time(dictation.createdAt) }

  var body: some View {
    Group {
      if idiom == .phone { phone } else { mac }
    }
    .contentShape(Rectangle())
    .contextMenu { menuItems }
    .accessibilityElement(children: .contain)
  }

  // MARK: - Layouts

  private var mac: some View {
    HStack(alignment: .top, spacing: Wisper.Space.m) {
      Text(time)
        .wisperText(.caption, color: Wisper.Color.textTertiary)
        .lineLimit(1)
        .padding(.top, Wisper.Space.xxs)
        .frame(width: Self.timeWidth, alignment: .leading)
      content
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(dictation.appName ?? "")
        .wisperText(.caption, color: Wisper.Color.textTertiary)
        .lineLimit(1)
        .padding(.top, Wisper.Space.xxs)
        .frame(width: Self.gutter, alignment: .trailing)
        .opacity(showsActions ? 0 : 1)
        .accessibilityLabel(dictation.appName.map { "In \($0)" } ?? "")
    }
    .padding(.vertical, Self.macRowPadding)
    .frame(minHeight: Self.macRowHeight, alignment: .top)
    .overlay(alignment: .topTrailing) {
      HStack(spacing: Wisper.Space.xxs) {
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
      .padding(.top, (Self.macRowHeight - Self.actionSide) / 2)
      .padding(.trailing, -Wisper.Space.xs)
      .opacity(showsActions ? 1 : 0)
    }
    .rowChrome(isHighlighted: showsActions)
    .onHover { isHovered = $0 }
    .animation(Wisper.Motion.quick, value: showsActions)
  }

  private var phone: some View {
    HStack(alignment: .top, spacing: Wisper.Space.xs) {
      VStack(alignment: .leading, spacing: Wisper.Space.xs) {
        content
        Text([time, dictation.appName].compactMap { $0 }.joined(separator: " · "))
          .wisperText(.caption, color: Wisper.Color.textTertiary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, Wisper.Space.m)
      OverflowMenu(label: "Actions") { menuItems }
        .padding(.top, Wisper.Space.xs)
    }
    .padding(.trailing, -Wisper.Space.s)
    .frame(minHeight: Self.phoneRowHeight)
    .rowChrome(isHighlighted: false)
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
    VStack(alignment: .leading, spacing: Wisper.Space.s) {
      if let failure = dictation.failure {
        failed(failure)
      } else {
        text
      }
      if dictation.mode == .command {
        HStack(spacing: Wisper.Space.s) {
          Badge("Command", tone: .accent)
          if !dictation.failed, !dictation.rawText.isEmpty {
            Text("You said: “\(dictation.rawText)”")
              .wisperText(.caption)
              .lineLimit(1)
          }
        }
      }
      if isPlaying {
        HStack(spacing: Wisper.Space.s) {
          IconButton("stop.fill", label: "Stop", size: .small, action: actions.togglePlayback)
          ProgressBar(value: player.progress)
          Text("\(HomeHistory.clock(player.elapsed)) / \(HomeHistory.clock(dictation.duration))")
            .wisperText(.caption, color: Wisper.Color.textTertiary)
            .monospacedDigit()
            .fixedSize()
            .accessibilityLabel("Playing the recording")
        }
        .padding(.leading, -Wisper.Space.xs)
      }
    }
  }

  private var text: some View {
    let lines = idiom == .phone ? 4 : 3
    let measures = HomeHistory.mayNeedCutting(dictation.text)
    let isCut = fullHeight > shownHeight + 1
    return VStack(alignment: .leading, spacing: Wisper.Space.xs) {
      Text(dictation.text)
        .wisperText(.body)
        .lineLimit(isExpanded ? nil : lines)
        .fixedSize(horizontal: false, vertical: true)
        .background {
          // The same text at full height, unseen, to learn whether lines were cut.
          if measures && !isExpanded {
            Text(dictation.text)
              .wisperText(.body)
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
          withAnimation(Wisper.Motion.smooth) { isExpanded.toggle() }
        }
        .buttonStyle(.plain)
        .wisperText(.captionStrong, color: Wisper.Color.accent)
        .frame(minHeight: idiom == .phone ? Self.touchHeight : nil)
        .contentShape(Rectangle())
      }
    }
  }

  private func failed(_ failure: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Wisper.Space.s) {
      Image(systemName: "exclamationmark.circle.fill")
        .wisperText(.caption, color: Wisper.Color.danger)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Wisper.Space.s) {
        VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
          Text("This one was not turned into text").wisperText(.bodyStrong)
          Text(failure)
            .wisperText(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        if isRetrying {
          HStack(spacing: Wisper.Space.s) {
            ProcessingIndicator(tint: Wisper.Color.textSecondary, height: Self.indicatorHeight)
            Text("Trying again…").wisperText(.caption)
          }
          .frame(minHeight: Self.retryHeight)
        } else if hasAudio {
          HStack(spacing: Wisper.Space.m) {
            Button("Retry", action: actions.retry)
              .buttonStyle(.wisper(.tertiary, size: .small))
              .disabled(!canRetry)
            Text("Your recording is saved.").wisperText(.caption)
          }
        } else {
          Text("The recording was not kept, so it cannot be tried again.")
            .wisperText(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
