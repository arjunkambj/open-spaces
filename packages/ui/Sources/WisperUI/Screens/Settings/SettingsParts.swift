import SwiftUI
import WisperDomain
import WisperEngine

/// Sizes the settings and onboarding screens share with the kit's setting rows.
enum SetupMetrics {
  /// The side inset of a `SettingRow`, so our own rows and dividers line up with it.
  static let rowInset: CGFloat = 20
  /// The width of a text field that sits at the end of a row on a Mac.
  static let rowFieldWidth: CGFloat = 240
  /// The widest a block of reading text gets.
  static let readingWidth: CGFloat = 560
}

extension AppModel {
  /// A binding that reads one setting and writes it straight back to the library.
  func settingBinding<Value: Sendable>(
    _ keyPath: WritableKeyPath<WisperDomain.Settings, Value> & Sendable
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
/// On a Mac the control sits at the end of the row, like `SettingRow`. On iPhone, and
/// always with `.stacked`, the control goes under the text and takes the full width.
struct SettingsItem<Control: View>: View {
  enum Layout {
    /// Beside the text on a Mac, under it on iPhone.
    case adaptive
    /// Always under the text.
    case stacked
  }

  private let title: String
  private let description: String?
  private let layout: Layout
  private let control: Control

  @Environment(\.wisperIdiom) private var idiom

  init(
    _ title: String,
    description: String? = nil,
    layout: Layout = .adaptive,
    @ViewBuilder control: () -> Control
  ) {
    self.title = title
    self.description = description
    self.layout = layout
    self.control = control()
  }

  var body: some View {
    if layout == .stacked || idiom == .phone {
      VStack(alignment: .leading, spacing: Wisper.Space.m) {
        VStack(alignment: .leading, spacing: Wisper.Space.xs) {
          Text(title).wisperText(.bodyStrong)
          if let description {
            Text(description)
              .wisperText(.caption)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        control
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, SetupMetrics.rowInset)
      .padding(.vertical, Wisper.Space.l)
    } else {
      SettingRow(title, description: description) { control }
    }
  }
}

/// A text link that opens a web page.
struct SetupLink: View {
  private let title: String
  private let url: URL
  private let style: Wisper.TextStyle

  @Environment(\.openURL) private var openURL

  init(_ title: String, url: URL, style: Wisper.TextStyle = .captionStrong) {
    self.title = title
    self.url = url
    self.style = style
  }

  var body: some View {
    Button {
      openURL(url)
    } label: {
      HStack(spacing: Wisper.Space.xs) {
        Text(title)
        Image(systemName: "arrow.up.right")
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      .wisperText(style, color: Wisper.Color.accent)
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
  private let style: Wisper.TextStyle

  init(_ text: String, style: Wisper.TextStyle = .body) {
    self.text = text
    self.style = style
  }

  var body: some View {
    Text(text)
      .wisperText(style, color: Wisper.Color.textSecondary)
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
    HStack(alignment: .top, spacing: Wisper.Space.m) {
      SymbolTile(systemImage, size: 36)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
        Text(title).wisperText(.bodyStrong)
        if let detail {
          Text(detail)
            .wisperText(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
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
      VStack(alignment: .leading, spacing: Wisper.Space.s) {
        Text(ServerAddress.keyNote)
          .wisperText(.caption)
          .fixedSize(horizontal: false, vertical: true)
        if address.isNotPrivate {
          HStack(alignment: .firstTextBaseline, spacing: Wisper.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
              .wisperText(.caption, color: Wisper.Color.warning)
              .accessibilityHidden(true)
            Text("\(ServerAddress.notPrivateTitle). \(ServerAddress.notPrivateMessage)")
              .wisperText(.caption, color: Wisper.Color.warning)
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
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.control, style: .continuous)
    HStack(alignment: .top, spacing: Wisper.Space.s) {
      // Every line is there to read: one that is too wide goes on below, under where it started.
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(CodeLine.lines(of: text).enumerated()), id: \.offset) { _, line in
          HStack(alignment: .top, spacing: 0) {
            Text(line.indent).wisperText(.mono).accessibilityHidden(true)
            Text(line.code)
              .wisperText(.mono)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, Wisper.Space.s)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityValue(text)
      IconButton(copied ? "checkmark" : "doc.on.doc", label: copied ? "Copied" : "Copy \(label)") {
        // A command or a path, nothing private.
        ScreenClipboard.copy(text, as: .plain)
        copied = true
      }
    }
    .padding(.leading, Wisper.Space.m)
    .padding(.trailing, Wisper.Space.xs)
    .padding(.vertical, Wisper.Space.xs)
    .background(Wisper.Color.raised, in: shape)
    .overlay { shape.strokeBorder(Wisper.Color.borderStrong, lineWidth: Wisper.Stroke.hairline) }
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
  @Environment(\.wisperIdiom) private var idiom

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
    HStack(alignment: .top, spacing: Wisper.Space.xs) {
      WisperTextField(
        label,
        text: $text,
        placeholder: "sk-...",
        error: error,
        isSecure: !isRevealed,
        focusOnAppear: focusOnAppear
      )
      #if os(iOS)
        .textInputAutocapitalization(.never)
      #endif
      .autocorrectionDisabled()
      VStack(spacing: Self.labelGap) {
        // Takes the room of the field's label, so the buttons line up with the box under it.
        Text(label)
          .wisperText(.captionStrong)
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
        .frame(minHeight: fieldHeight)
      }
    }
  }

  static let openAILabel = "OpenAI API key"
  static let serverLabel = "API key"
  /// The gap `WisperTextField` leaves between its label and its box.
  private static let labelGap: CGFloat = 6
  /// The height of a `WisperTextField`, so the buttons centre on the box and not on the error under it.
  private var fieldHeight: CGFloat { idiom == .phone ? 48 : 38 }
}
