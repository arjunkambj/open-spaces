import SwiftUI
import WisperDomain
import WisperUI

/// The keyboard's face: a Dictate key that opens the app, a key that types the latest
/// dictation, the person's snippets, and the few keys every keyboard needs.
public struct KeyboardPanel: View {
  private let model: KeyboardModel

  public init(model: KeyboardModel) {
    self.model = model
  }

  /// The height the keyboard asks the system for, in points.
  public static let height: CGFloat = 216

  public var body: some View {
    VStack(spacing: Wisper.Space.s) {
      top
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      HStack(spacing: Wisper.Space.s) {
        Button {
          Task { await model.dictate() }
        } label: {
          FittedLabel("Dictate", short: "Dictate", systemImage: "mic.fill")
        }
        .buttonStyle(.wisper(.primary, fullWidth: true))
        .accessibilityHint("Opens Open Wisper to listen")

        Button {
          model.insertLatest()
        } label: {
          FittedLabel("Insert latest", short: "Insert", systemImage: "text.insert")
        }
        .buttonStyle(.wisper(.tertiary, fullWidth: true))
        .disabled(model.latest == nil)
        .accessibilityHint("Types your most recent dictation")
      }
      bottomRow
    }
    .padding(.horizontal, Wisper.Space.s)
    .padding(.top, Wisper.Space.s)
    .padding(.bottom, Wisper.Space.xs)
    .frame(height: KeyboardPanel.height)
    .environment(\.wisperIdiom, .phone)
    // Like the system keyboard, this one has a fixed height: its text stops growing early.
    .dynamicTypeSize(...DynamicTypeSize.xLarge)
  }

  // MARK: Above the keys

  /// A message when something needs the person's attention, otherwise the snippets.
  @ViewBuilder private var top: some View {
    if let hint = model.hint {
      Notice(symbol: "exclamationmark.circle", title: hint, detail: nil)
    } else if let problem = model.problem {
      switch problem {
      case .needsFullAccess:
        Notice(
          symbol: "lock.open",
          title: "Turn on Allow Full Access",
          detail: "Open Wisper needs it to open the app and to type your snippets. "
            + "In Settings, go to General, Keyboard, Keyboards, Open Wisper."
        )
      case .noSharedFolder:
        Notice(
          symbol: "folder.badge.questionmark",
          title: "This keyboard cannot reach the app's data",
          detail: "This copy of Open Wisper was built without its App Group. See the README in apps/ios."
        )
      case .cannotRead(let message):
        Notice(symbol: "exclamationmark.triangle", title: "Could not read your library", detail: message)
      }
    } else {
      VStack(alignment: .leading, spacing: Wisper.Space.xs) {
        latestLine
        snippetRow
      }
    }
  }

  private var latestLine: some View {
    HStack(spacing: Wisper.Space.s) {
      WisperGlyph(size: 14, tint: Wisper.Color.textSecondary)
      Text(model.latest ?? "Tap Dictate, speak, then come back here.")
        .wisperText(.caption)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Wisper.Space.xs)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(model.latest.map { "Latest dictation: \($0)" } ?? "No dictation yet")
  }

  @ViewBuilder private var snippetRow: some View {
    if model.snippets.isEmpty {
      Text("Snippets you save in the app show up here.")
        .wisperText(.caption, color: Wisper.Color.textTertiary)
        .frame(maxWidth: .infinity, minHeight: KeyMetrics.chipHeight, alignment: .leading)
        .padding(.horizontal, Wisper.Space.xs)
    } else {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Wisper.Space.s) {
          ForEach(model.snippets) { snippet in
            Button(snippet.trigger) { model.insert(snippet) }
              .buttonStyle(.wisper(.tertiary, size: .small))
              .accessibilityHint("Types this snippet")
          }
        }
        .padding(.horizontal, Wisper.Space.xxs)
      }
      .frame(minHeight: KeyMetrics.chipHeight)
    }
  }

  // MARK: The basic keys

  private var bottomRow: some View {
    HStack(spacing: Wisper.Space.s) {
      if model.showsGlobeKey {
        Button {
          model.nextKeyboard()
        } label: {
          Key(width: KeyMetrics.narrow) { Image(systemName: "globe") }
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel("Next keyboard")
      }
      Button {
        model.space()
      } label: {
        Key(width: nil) { Text("space") }
      }
      .buttonStyle(KeyPressStyle())
      .accessibilityLabel("Space")

      DeleteKey(began: model.deleteBegan, ended: model.deleteEnded)

      Button {
        model.newLine()
      } label: {
        Key(width: KeyMetrics.wide) { Text("return") }
      }
      .buttonStyle(KeyPressStyle())
      .accessibilityLabel("Return")
    }
  }
}

private enum KeyMetrics {
  static let keyHeight: CGFloat = 44
  static let chipHeight: CGFloat = 44
  static let narrow: CGFloat = 48
  static let wide: CGFloat = 84
}

/// A key's icon and name, cut down to what fits on a narrow phone.
private struct FittedLabel: View {
  private let title: String
  private let short: String
  private let systemImage: String

  init(_ title: String, short: String, systemImage: String) {
    self.title = title
    self.short = short
    self.systemImage = systemImage
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      Label(title, systemImage: systemImage)
      Text(title)
      Text(short)
    }
  }
}

/// One of the plain keys in the bottom row.
private struct Key<Face: View>: View {
  let width: CGFloat?
  var isPressed = false
  @ViewBuilder let face: Face

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.control, style: .continuous)
    face
      .wisperText(.bodyStrong)
      .frame(maxWidth: width ?? .infinity)
      .frame(width: width, height: KeyMetrics.keyHeight)
      .background(isPressed ? Wisper.Color.surfaceSelected : Wisper.Color.raised, in: shape)
      .overlay { shape.strokeBorder(Wisper.Color.border, lineWidth: Wisper.Stroke.hairline) }
      .contentShape(shape)
  }
}

/// Darkens a key while a finger is on it.
private struct KeyPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.6 : 1)
      .animation(Wisper.Motion.quick, value: configuration.isPressed)
  }
}

/// The delete key. It acts when the finger goes down and repeats while it stays there,
/// which a plain button cannot do.
private struct DeleteKey: View {
  let began: () -> Void
  let ended: () -> Void

  @State private var isDown = false

  var body: some View {
    Key(width: KeyMetrics.narrow, isPressed: isDown) { Image(systemName: "delete.left") }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            guard !isDown else { return }
            isDown = true
            began()
          }
          .onEnded { _ in
            isDown = false
            ended()
          }
      )
      .onDisappear(perform: ended)
      .accessibilityElement()
      .accessibilityLabel("Delete")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        began()
        ended()
      }
  }
}

/// A short message in place of the snippets.
private struct Notice: View {
  let symbol: String
  let title: String
  let detail: String?

  var body: some View {
    HStack(alignment: .top, spacing: Wisper.Space.s) {
      Image(systemName: symbol)
        .wisperText(.bodyStrong, color: Wisper.Color.warning)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
        Text(title)
          .wisperText(.captionStrong)
          .fixedSize(horizontal: false, vertical: true)
        if let detail {
          Text(detail)
            .wisperText(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Wisper.Space.s)
    .accessibilityElement(children: .combine)
  }
}
