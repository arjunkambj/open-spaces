import SpacesDomain
import SpacesEngine
import SwiftUI

/// Sizes the settings and onboarding screens share with the kit's setting rows.
enum SetupMetrics {
  /// The side inset of a `SettingRow`, so our own rows and dividers line up with it.
  static let rowInset = Spaces.Space.xl
  /// The width of a text field that sits at the end of a row.
  static let rowFieldWidth: CGFloat = 240
  /// The widest a block of reading text gets.
  static let readingWidth: CGFloat = 560
}

extension AppModel {
  /// A binding that reads one setting and writes it straight back to the library.
  func settingBinding<Value: Sendable>(
    _ keyPath: WritableKeyPath<SpacesDomain.Settings, Value> & Sendable
  ) -> Binding<Value> {
    Binding(
      get: { self.settings[keyPath: keyPath] },
      set: { value in self.update { $0[keyPath: keyPath] = value } }
    )
  }
}

/// The hairline between two rows of a settings card.
struct SettingsDivider: View {
  var body: some View {
    Hairline().padding(.horizontal, SetupMetrics.rowInset)
  }
}

/// One setting with a control that needs room, such as a text field or a select box.
///
/// The control sits at the end of the row, like `SettingRow`. With `.stacked` it goes under
/// the text and takes the full width.
struct SettingsItem<Control: View>: View {
  enum Layout {
    /// At the end of the row, beside the text.
    case beside
    /// Always under the text.
    case stacked
  }

  private let title: String
  private let description: String?
  private let layout: Layout
  private let control: Control

  init(
    _ title: String,
    description: String? = nil,
    layout: Layout = .beside,
    @ViewBuilder control: () -> Control
  ) {
    self.title = title
    self.description = description
    self.layout = layout
    self.control = control()
  }

  var body: some View {
    if layout == .stacked {
      VStack(alignment: .leading, spacing: Spaces.Space.m) {
        VStack(alignment: .leading, spacing: Spaces.Space.xs) {
          Text(title).spacesText(.bodyStrong)
          if let description {
            Text(description)
              .spacesText(.caption)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        control
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, SetupMetrics.rowInset)
      .padding(.vertical, Spaces.Space.l)
    } else {
      SettingRow(title, description: description) { control }
    }
  }
}

/// A text link that opens a web page.
struct SetupLink: View {
  private let title: String
  private let url: URL
  private let style: Spaces.TextStyle

  @Environment(\.openURL) private var openURL

  init(_ title: String, url: URL, style: Spaces.TextStyle = .captionStrong) {
    self.title = title
    self.url = url
    self.style = style
  }

  var body: some View {
    Button {
      openURL(url)
    } label: {
      HStack(spacing: Spaces.Space.xs) {
        Text(title)
        Image(systemName: "arrow.up.right")
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      .spacesText(style, color: Spaces.Color.accent)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityHint("Opens in your browser")
    .accessibilityAddTraits(.isLink)
  }
}

/// A paragraph of reading text.
struct SetupParagraph: View {
  private let text: String
  private let style: Spaces.TextStyle

  init(_ text: String, style: Spaces.TextStyle = .body) {
    self.text = text
    self.style = style
  }

  var body: some View {
    Text(text)
      .spacesText(style, color: Spaces.Color.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: SetupMetrics.readingWidth, alignment: .leading)
  }
}

/// A fact with an icon in front: used for short lists of plain statements.
struct SetupFact: View {
  private let systemImage: String
  private let title: String
  private let detail: String?

  init(_ systemImage: String, title: String, detail: String? = nil) {
    self.systemImage = systemImage
    self.title = title
    self.detail = detail
  }

  var body: some View {
    HStack(alignment: .top, spacing: Spaces.Space.m) {
      SymbolTile(systemImage, size: 36)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
        Text(title).spacesText(.bodyStrong)
        if let detail {
          Text(detail)
            .spacesText(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

/// A small dot: filled while an AI tool is connected, an outline once it is not.
struct AgentDot: View {
  let isConnected: Bool

  var body: some View {
    Circle()
      .strokeBorder(
        isConnected ? Spaces.Color.success : Spaces.Color.textTertiary,
        lineWidth: Spaces.Stroke.focus
      )
      .background(Circle().fill(isConnected ? Spaces.Color.success : SwiftUI.Color.clear))
      .frame(width: Spaces.Space.s, height: Spaces.Space.s)
      .accessibilityHidden(true)
  }
}

/// What to know about a custom server address, shown under the field it is typed into: the key
/// goes there, and a warning when the connection can be read by others. Nothing for OpenAI itself.
///
/// Both are short lines of text, so they stay in view under the field in a small window.
struct ServerNotice: View {
  let address: ServerAddress

  var body: some View {
    if address.address != nil {
      VStack(alignment: .leading, spacing: Spaces.Space.s) {
        Text(ServerAddress.keyNote)
          .spacesText(.caption)
          .fixedSize(horizontal: false, vertical: true)
        if address.isNotPrivate {
          HStack(alignment: .firstTextBaseline, spacing: Spaces.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
              .spacesText(.caption, color: Spaces.Color.warning)
              .accessibilityHidden(true)
            Text("\(ServerAddress.notPrivateTitle). \(ServerAddress.notPrivateMessage)")
              .spacesText(.caption, color: Spaces.Color.warning)
              .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityElement(children: .combine)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Text to copy, in fixed-width type, with a copy button.
struct CopyBlock: View {
  private let label: String
  private let text: String

  @State private var copied = false

  /// - label: what the text is, for VoiceOver, e.g. "Claude Code command".
  init(_ label: String, text: String) {
    self.label = label
    self.text = text
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.control, style: .continuous)
    HStack(alignment: .top, spacing: Spaces.Space.s) {
      // Every line is there to read: one that is too wide goes on below, under where it started.
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(CodeLine.lines(of: text).enumerated()), id: \.offset) { _, line in
          HStack(alignment: .top, spacing: 0) {
            Text(line.indent).spacesText(.mono).accessibilityHidden(true)
            Text(line.code)
              .spacesText(.mono)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, Spaces.Space.s)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityValue(text)
      IconButton(copied ? "checkmark" : "doc.on.doc", label: copied ? "Copied" : "Copy \(label)") {
        // A command or a path, nothing private.
        ScreenClipboard.copy(text)
        copied = true
      }
    }
    .padding(.leading, Spaces.Space.m)
    .padding(.trailing, Spaces.Space.xs)
    .padding(.vertical, Spaces.Space.xs)
    .background(Spaces.Color.raised, in: shape)
    .overlay { shape.strokeBorder(Spaces.Color.borderStrong, lineWidth: Spaces.Stroke.hairline) }
    .task(id: copied) {
      guard copied else { return }
      try? await Task.sleep(for: .seconds(1.6))
      if !Task.isCancelled { copied = false }
    }
  }
}

/// One line of code to show: the blank space it starts with, and the rest. They are drawn side
/// by side, so a line too wide for its box goes on under its own first letter and keeps its indent.
struct CodeLine: Equatable {
  var indent: String
  var code: String

  static func lines(of text: String) -> [CodeLine] {
    text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
      let code = line.drop { $0 == " " || $0 == "\t" }
      return CodeLine(indent: String(line.dropLast(code.count)), code: String(code))
    }
  }
}

/// The field an OpenAI key is pasted into: hidden by default, with show/hide and paste buttons.
struct APIKeyField: View {
  private let label: String
  @Binding private var text: String
  private let error: String?
  private let focusOnAppear: Bool

  @State private var isRevealed = false

  /// - label: what the key is for. A key for a server of the person's own is not an OpenAI key.
  /// - focusOnAppear: puts the cursor in the field when it shows. For a dialog.
  init(
    _ label: String = APIKeyField.openAILabel,
    text: Binding<String>,
    error: String? = nil,
    focusOnAppear: Bool = false
  ) {
    self.label = label
    _text = text
    self.error = error
    self.focusOnAppear = focusOnAppear
  }

  var body: some View {
    HStack(alignment: .top, spacing: Spaces.Space.xs) {
      SpacesTextField(
        label,
        text: $text,
        placeholder: "sk-...",
        error: error,
        isSecure: !isRevealed,
        focusOnAppear: focusOnAppear
      )
      .autocorrectionDisabled()
      VStack(spacing: Self.labelGap) {
        // Takes the room of the field's label, so the buttons line up with the box under it.
        Text(label)
          .spacesText(.captionStrong)
          .hidden()
          .accessibilityHidden(true)
        HStack(spacing: 0) {
          IconButton(isRevealed ? "eye.slash" : "eye", label: isRevealed ? "Hide key" : "Show key") {
            isRevealed.toggle()
          }
          IconButton("doc.on.clipboard", label: "Paste key") {
            if let pasted = ScreenClipboard.text() {
              text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            }
          }
        }
        .frame(minHeight: Self.fieldHeight)
      }
    }
  }

  static let openAILabel = "OpenAI API key"
  static let serverLabel = "API key"
  /// The gap `SpacesTextField` leaves between its label and its box.
  private static let labelGap: CGFloat = 6
  /// The height of a `SpacesTextField`, so the buttons centre on the box and not on the error under it.
  private static let fieldHeight: CGFloat = 38
}
