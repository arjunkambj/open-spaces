import SwiftUI

/// The Spaces switch. Use it as `.toggleStyle(.spaces)`: the label on the left,
/// the switch on the right, and the whole line toggles.
public struct SpacesToggleStyle: ToggleStyle {
  public func makeBody(configuration: Configuration) -> some View {
    ToggleBody(configuration: configuration)
  }
}

extension ToggleStyle where Self == SpacesToggleStyle {
  /// The Spaces switch.
  public static var spaces: SpacesToggleStyle { SpacesToggleStyle() }
}

private struct ToggleBody: View {
  let configuration: ToggleStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.spacesIdiom) private var idiom

  var body: some View {
    let width: CGFloat = idiom == .phone ? 51 : 36
    let height: CGFloat = idiom == .phone ? 31 : 20
    let inset: CGFloat = 2
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: Spaces.Space.l) {
        configuration.label
          .frame(maxWidth: .infinity, alignment: .leading)
        Capsule()
          .fill(configuration.isOn ? Spaces.Color.inverse : Spaces.Color.track)
          .frame(width: width, height: height)
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle()
              .fill(configuration.isOn ? Spaces.Color.onInverse : Spaces.Color.knob)
              .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
              .padding(inset)
          }
          .animation(Spaces.Motion.smooth, value: configuration.isOn)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.45)
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
    }
  }
}

/// One setting: a title and helper text on the left, a control on the right.
///
///     SettingRow("Microphone", description: "Built-in microphone") {
///       Button("Change") { ... }.buttonStyle(.spaces())
///     }
///
/// Put rows in a `Card(padding: 0)` with a `Hairline()` between them.
public struct SettingRow<Control: View>: View {
  private let title: String
  private let description: String?
  private let control: Control

  public init(_ title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
    self.title = title
    self.description = description
    self.control = control()
  }

  public var body: some View {
    HStack(alignment: .center, spacing: Spaces.Space.l) {
      SettingText(title: title, description: description)
        .frame(maxWidth: .infinity, alignment: .leading)
      control
    }
    .padding(.horizontal, Spaces.Space.xl)
    .padding(.vertical, Spaces.Space.l)
    .frame(minHeight: 64)
  }
}

/// A setting that is on or off. The whole row toggles it.
public struct ToggleRow: View {
  private let title: String
  private let description: String?
  @Binding private var isOn: Bool

  public init(_ title: String, description: String? = nil, isOn: Binding<Bool>) {
    self.title = title
    self.description = description
    _isOn = isOn
  }

  public var body: some View {
    Toggle(isOn: $isOn) {
      SettingText(title: title, description: description)
    }
    .toggleStyle(.spaces)
    .padding(.horizontal, Spaces.Space.xl)
    .padding(.vertical, Spaces.Space.l)
    .frame(minHeight: 64)
  }
}

private struct SettingText: View {
  let title: String
  let description: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.xs) {
      Text(title).spacesText(.bodyStrong)
      if let description {
        Text(description)
          .spacesText(.caption)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// A select box: shows the current choice and opens a menu of the others.
///
///     Dropdown("Theme", selection: $theme, options: Theme.allCases) { $0.title }
public struct Dropdown<Value: Hashable>: View {
  private let label: String
  @Binding private var selection: Value
  private let options: [Value]
  private let title: (Value) -> String

  @Environment(\.spacesIdiom) private var idiom

  /// - label: the VoiceOver name of the control. It is not drawn.
  /// - title: the text shown for an option.
  public init(
    _ label: String,
    selection: Binding<Value>,
    options: [Value],
    title: @escaping (Value) -> String
  ) {
    self.label = label
    _selection = selection
    self.options = options
    self.title = title
  }

  public var body: some View {
    menu
      .menuIndicator(.hidden)
      .frame(minWidth: idiom == .phone ? 140 : 170)
      .fixedSize()
      .accessibilityLabel(label)
      .accessibilityValue(title(selection))
  }

  // The Mac draws a menu's label as a system button unless it is given a button style;
  // iOS draws the label as it is.
  @ViewBuilder private var menu: some View {
    #if os(macOS)
      Menu {
        choices
      } label: {
        current
      }
      .menuStyle(.button)
      .buttonStyle(DropdownButtonStyle())
    #else
      Menu {
        choices
      } label: {
        DropdownBox { current }
      }
    #endif
  }

  private var choices: some View {
    Picker(label, selection: $selection) {
      ForEach(options, id: \.self) { option in
        Text(title(option)).tag(option)
      }
    }
    .pickerStyle(.inline)
    .labelsHidden()
  }

  private var current: some View {
    HStack(spacing: Spaces.Space.m) {
      Text(title(selection))
        .spacesText(.body)
        .lineLimit(1)
      Spacer(minLength: 0)
      Image(systemName: "chevron.down")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Spaces.Color.textSecondary)
    }
  }
}

private struct DropdownButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    DropdownBox { configuration.label }
  }
}

/// The bordered box of a select box.
private struct DropdownBox<Label: View>: View {
  @ViewBuilder let label: Label
  @Environment(\.spacesIdiom) private var idiom
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.control, style: .continuous)
    label
      .padding(.horizontal, Spaces.Space.m)
      .frame(minHeight: idiom == .phone ? 44 : 36)
      .background(isHovered ? Spaces.Color.surfaceHover : Spaces.Color.raised, in: shape)
      .overlay { shape.strokeBorder(Spaces.Color.borderStrong, lineWidth: Spaces.Stroke.hairline) }
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(shape)
      .onHover { isHovered = $0 }
      .animation(Spaces.Motion.quick, value: isHovered)
  }
}

/// How `Tabs` are drawn.
public enum TabsStyle: Sendable {
  /// Text tabs on a hairline, the current one underlined. For the top of a page.
  case underline
  /// A compact capsule of segments. For a choice inside a card or on iPhone.
  case segmented
}

/// A row of tabs to switch between a few views of the same thing.
///
///     Tabs(selection: $tab, options: Tab.allCases) { $0.title } trailing: {
///       SearchField(text: $query)
///     }
public struct Tabs<Value: Hashable, Trailing: View>: View {
  @Binding private var selection: Value
  private let options: [Value]
  private let style: TabsStyle
  private let title: (Value) -> String
  private let trailing: Trailing

  @Namespace private var namespace
  @Environment(\.spacesIdiom) private var idiom

  /// - trailing: sits at the end of the tab line (underline style only), e.g. a search field.
  public init(
    selection: Binding<Value>,
    options: [Value],
    style: TabsStyle = .underline,
    title: @escaping (Value) -> String,
    @ViewBuilder trailing: () -> Trailing = { EmptyView() }
  ) {
    _selection = selection
    self.options = options
    self.style = style
    self.title = title
    self.trailing = trailing()
  }

  public var body: some View {
    Group {
      switch style {
      case .underline: underline
      case .segmented: segmented
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isTabBar)
  }

  private var underline: some View {
    HStack(alignment: .bottom, spacing: Spaces.Space.xl) {
      ForEach(options, id: \.self) { option in
        let isSelected = option == selection
        Button {
          withAnimation(Spaces.Motion.smooth) { selection = option }
        } label: {
          Text(title(option))
            .spacesText(
              .bodyStrong,
              color: isSelected ? Spaces.Color.textPrimary : Spaces.Color.textSecondary
            )
            .lineLimit(1)
            .padding(.bottom, Spaces.Space.m)
            .overlay(alignment: .bottom) {
              if isSelected {
                Rectangle()
                  .fill(Spaces.Color.textPrimary)
                  .frame(height: Spaces.Stroke.focus)
                  .matchedGeometryEffect(id: "underline", in: namespace)
              }
            }
            .frame(minHeight: 36, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
      Spacer(minLength: 0)
      HStack(spacing: Spaces.Space.xs) { trailing }
        .padding(.bottom, Spaces.Space.xs)
    }
    .overlay(alignment: .bottom) { Hairline() }
  }

  private var segmented: some View {
    HStack(spacing: Spaces.Space.xxs) {
      ForEach(options, id: \.self) { option in
        let isSelected = option == selection
        let shape = PillShape()
        Button {
          withAnimation(Spaces.Motion.smooth) { selection = option }
        } label: {
          Text(title(option))
            .spacesText(
              .captionStrong,
              color: isSelected ? Spaces.Color.textPrimary : Spaces.Color.textSecondary
            )
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, Spaces.Space.m)
            .frame(maxWidth: .infinity, minHeight: idiom == .phone ? 36 : 28)
            .background {
              if isSelected {
                shape
                  .fill(Spaces.Color.segment)
                  .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                  .matchedGeometryEffect(id: "segment", in: namespace)
              }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .padding(Spaces.Space.xxs)
    .background(Spaces.Color.surfaceHover, in: Capsule())
  }
}

/// A small label with a word in it: "New", "Beta", a status.
///
/// The tones are black and white: `accent` is solid ink, `warning` an outline, `danger` red.
/// `neutral` and `success` are quiet grey; let the word say which.
public struct Badge: View {
  public enum Tone: Sendable {
    case neutral, accent, success, warning, danger
  }

  private let text: String
  private let tone: Tone

  public init(_ text: String, tone: Tone = .neutral) {
    self.text = text
    self.tone = tone
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.small, style: .continuous)
    Text(text)
      .font(.system(size: 11.5, weight: .medium))
      .foregroundStyle(foreground)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(fill, in: shape)
      .overlay {
        if tone == .warning {
          shape.strokeBorder(Spaces.Color.borderStrong, lineWidth: Spaces.Stroke.hairline)
        }
      }
  }

  /// How strongly the danger tone colours its own background.
  nonisolated static let tintOpacity = 0.12

  private var fill: SwiftUI.Color {
    switch tone {
    case .neutral, .success: Spaces.Color.surfaceSelected
    case .accent: Spaces.Color.accent
    case .warning: .clear
    case .danger: Spaces.Color.danger.opacity(Self.tintOpacity)
    }
  }

  private var foreground: SwiftUI.Color {
    switch tone {
    case .neutral: Spaces.Color.textSecondary
    case .accent: Spaces.Color.onAccent
    case .success, .warning: Spaces.Color.textPrimary
    case .danger: Spaces.Color.danger
    }
  }
}
