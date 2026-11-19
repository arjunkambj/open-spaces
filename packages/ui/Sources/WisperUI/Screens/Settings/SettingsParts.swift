import SwiftUI
import WisperDomain
import WisperEngine

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

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

/// The system clipboard.
@MainActor
enum SetupClipboard {
  static func copy(_ text: String) {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #elseif canImport(UIKit)
      UIPasteboard.general.string = text
    #endif
  }

  static func text() -> String? {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
      NSPasteboard.general.string(forType: .string)
    #elseif canImport(UIKit)
      UIPasteboard.general.string
    #else
      nil
    #endif
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
      Group {
        if text.contains("\n") {
          // Code of several lines keeps its line breaks and scrolls sideways when it is too wide.
          ScrollView(.horizontal, showsIndicators: false) {
            code.fixedSize()
          }
        } else {
          code.fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, Wisper.Space.s)
      IconButton(copied ? "checkmark" : "doc.on.doc", label: copied ? "Copied" : "Copy \(label)") {
        SetupClipboard.copy(text)
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

  private var code: some View {
    Text(text)
      .wisperText(.mono)
      .textSelection(.enabled)
      .accessibilityLabel(label)
      .accessibilityValue(text)
  }
}

/// The field an OpenAI key is pasted into: hidden by default, with show/hide and paste buttons.
struct APIKeyField: View {
  @Binding private var text: String
  private let error: String?

  @State private var isRevealed = false
  @Environment(\.wisperIdiom) private var idiom

  init(text: Binding<String>, error: String? = nil) {
    _text = text
    self.error = error
  }

  var body: some View {
    HStack(alignment: .top, spacing: Wisper.Space.xs) {
      WisperTextField(Self.label, text: $text, placeholder: "sk-...", error: error, isSecure: !isRevealed)
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
        .autocorrectionDisabled()
      VStack(spacing: Self.labelGap) {
        // Takes the room of the field's label, so the buttons line up with the box under it.
        Text(Self.label)
          .wisperText(.captionStrong)
          .hidden()
          .accessibilityHidden(true)
        HStack(spacing: 0) {
          IconButton(isRevealed ? "eye.slash" : "eye", label: isRevealed ? "Hide key" : "Show key") {
            isRevealed.toggle()
          }
          IconButton("doc.on.clipboard", label: "Paste key") {
            if let pasted = SetupClipboard.text() {
              text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            }
          }
        }
        .frame(minHeight: fieldHeight)
      }
    }
  }

  private static let label = "OpenAI API key"
  /// The gap `WisperTextField` leaves between its label and its box.
  private static let labelGap: CGFloat = 6
  /// The height of a `WisperTextField`, so the buttons centre on the box and not on the error under it.
  private var fieldHeight: CGFloat { idiom == .phone ? 48 : 38 }
}
