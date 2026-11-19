import SwiftUI

/// A one-line text field with an optional label above and error text below.
///
///     WisperTextField("Your name", text: $name, placeholder: "e.g. Sam")
///
/// `.onSubmit { }` on the field runs when Return is pressed.
public struct WisperTextField: View {
  private let label: String?
  @Binding private var text: String
  private let placeholder: String
  private let error: String?
  private let isSecure: Bool
  private let focusOnAppear: Bool

  @Environment(\.wisperIdiom) private var idiom
  @FocusState private var isFocused: Bool

  /// - error: shown in red under the field; also turns the border red.
  /// - isSecure: hides what is typed, for secrets such as an API key.
  /// - focusOnAppear: puts the cursor in the field when it shows. For the first field of a dialog.
  public init(
    _ label: String? = nil,
    text: Binding<String>,
    placeholder: String = "",
    error: String? = nil,
    isSecure: Bool = false,
    focusOnAppear: Bool = false
  ) {
    self.label = label
    _text = text
    self.placeholder = placeholder
    self.error = error
    self.isSecure = isSecure
    self.focusOnAppear = focusOnAppear
  }

  public var body: some View {
    FieldFrame(label: label, error: error) {
      Group {
        if isSecure {
          SecureField("", text: $text, prompt: prompt)
        } else {
          TextField("", text: $text, prompt: prompt)
        }
      }
      .textFieldStyle(.plain)
      .wisperText(.body)
      .focused($isFocused)
      .focusEffectDisabled()
      .padding(.horizontal, Wisper.Space.m)
      .frame(minHeight: idiom == .phone ? 48 : 38)
      .fieldBox(isFocused: isFocused, hasError: error != nil)
      .accessibilityLabel(label ?? placeholder)
      .onAppear {
        if focusOnAppear { isFocused = true }
      }
      .task {
        // Asked again a moment later: a field that has only just been put in a window can
        // miss the first request.
        if focusOnAppear, !isFocused { isFocused = true }
      }
    }
  }

  private var prompt: Text {
    Text(placeholder).foregroundStyle(Wisper.Color.textTertiary)
  }
}

/// A text box for several lines, with an optional label above and error text below.
public struct WisperTextEditor: View {
  private let label: String?
  @Binding private var text: String
  private let placeholder: String
  private let error: String?
  private let height: CGFloat

  @FocusState private var isFocused: Bool

  /// - height: the height of the box, in points. Longer text scrolls inside it.
  public init(
    _ label: String? = nil,
    text: Binding<String>,
    placeholder: String = "",
    error: String? = nil,
    height: CGFloat = 96
  ) {
    self.label = label
    _text = text
    self.placeholder = placeholder
    self.error = error
    self.height = height
  }

  public var body: some View {
    FieldFrame(label: label, error: error) {
      TextEditor(text: $text)
        .wisperText(.body)
        .scrollContentBackground(.hidden)
        .focused($isFocused)
        .focusEffectDisabled()
        .padding(.horizontal, editorInset)
        .padding(.vertical, Wisper.Space.s)
        .frame(height: height)
        .overlay(alignment: .topLeading) {
          if text.isEmpty {
            Text(placeholder)
              .wisperText(.body, color: Wisper.Color.textTertiary)
              .padding(.horizontal, Wisper.Space.m)
              .padding(.vertical, Wisper.Space.s)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        .fieldBox(isFocused: isFocused, hasError: error != nil)
        .accessibilityLabel(label ?? placeholder)
    }
  }

  /// The system editor already insets its text by about five points on each side.
  private var editorInset: CGFloat { Wisper.Space.m - 5 }
}

/// Label above, error below.
private struct FieldFrame<Field: View>: View {
  let label: String?
  let error: String?
  @ViewBuilder let field: Field

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let label {
        Text(label).wisperText(.captionStrong)
      }
      field
      if let error {
        Label(error, systemImage: "exclamationmark.circle.fill")
          .labelStyle(.titleAndIcon)
          .wisperText(.caption, color: Wisper.Color.danger)
      }
    }
  }
}

/// The white box, border and focus look shared by every field.
private struct FieldBox: ViewModifier {
  let isFocused: Bool
  let hasError: Bool
  @Environment(\.simulatedFocus) private var simulatedFocus

  func body(content: Content) -> some View {
    let focused = isFocused || simulatedFocus
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.control, style: .continuous)
    let border =
      hasError ? Wisper.Color.danger : focused ? Wisper.Color.textPrimary : Wisper.Color.borderStrong
    content
      .background(Wisper.Color.raised, in: shape)
      .overlay {
        shape.strokeBorder(
          border,
          lineWidth: focused || hasError ? Wisper.Stroke.focus : Wisper.Stroke.hairline
        )
      }
      .animation(Wisper.Motion.quick, value: isFocused)
  }
}

extension View {
  fileprivate func fieldBox(isFocused: Bool, hasError: Bool) -> some View {
    modifier(FieldBox(isFocused: isFocused, hasError: hasError))
  }
}

/// A search box. On a Mac it is a magnifier icon that opens into a field when clicked;
/// on iPhone it is always a field.
public struct SearchField: View {
  @Binding private var text: String
  private let placeholder: String

  @Environment(\.wisperIdiom) private var idiom
  @Environment(\.simulatedFocus) private var simulatedFocus
  @FocusState private var isFocused: Bool
  @State private var isOpen = false

  public init(text: Binding<String>, placeholder: String = "Search") {
    _text = text
    self.placeholder = placeholder
  }

  public var body: some View {
    let expanded = idiom == .phone || isOpen || simulatedFocus || !text.isEmpty
    Group {
      if expanded {
        field
          .transition(.opacity)
          .onAppear {
            // Opened from the icon: put the cursor in the new field.
            if isOpen { isFocused = true }
          }
      } else {
        IconButton("magnifyingglass", label: placeholder) {
          withAnimation(Wisper.Motion.smooth) { isOpen = true }
        }
      }
    }
    #if os(macOS)
      .onExitCommand {
        text = ""
        isFocused = false
        withAnimation(Wisper.Motion.smooth) { isOpen = false }
      }
    #endif
    .onChange(of: isFocused) { _, focused in
      if !focused && text.isEmpty {
        withAnimation(Wisper.Motion.smooth) { isOpen = false }
      }
    }
  }

  private var field: some View {
    let phone = idiom == .phone
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.control, style: .continuous)
    return HStack(spacing: Wisper.Space.s) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: phone ? 16 : 13, weight: .medium))
        .foregroundStyle(Wisper.Color.textSecondary)
      TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Wisper.Color.textTertiary))
        .textFieldStyle(.plain)
        .wisperText(phone ? .body : .caption, color: Wisper.Color.textPrimary)
        .focused($isFocused)
        .focusEffectDisabled()
        .accessibilityLabel(placeholder)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: phone ? 16 : 13))
            .foregroundStyle(Wisper.Color.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, phone ? Wisper.Space.m : 10)
    .frame(width: phone ? nil : 220, height: phone ? 44 : 32)
    .background(phone ? Wisper.Color.surface : Wisper.Color.raised, in: shape)
    .overlay {
      shape.strokeBorder(
        isFocused ? Wisper.Color.textPrimary : Wisper.Color.borderStrong,
        lineWidth: Wisper.Stroke.hairline
      )
    }
  }
}
