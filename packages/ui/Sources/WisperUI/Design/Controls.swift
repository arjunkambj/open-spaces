import SwiftUI

/// The Open Wisper switch. Use it as `.toggleStyle(.wisper)`: the label on the left,
/// the switch on the right, and the whole line toggles.
public struct WisperToggleStyle: ToggleStyle {
  public func makeBody(configuration: Configuration) -> some View {
    ToggleBody(configuration: configuration)
  }
}

extension ToggleStyle where Self == WisperToggleStyle {
  /// The Open Wisper switch.
  public static var wisper: WisperToggleStyle { WisperToggleStyle() }
}

private struct ToggleBody: View {
  let configuration: ToggleStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.wisperIdiom) private var idiom

  var body: some View {
    let width: CGFloat = idiom == .phone ? 51 : 42
    let height: CGFloat = idiom == .phone ? 31 : 24
    let inset: CGFloat = idiom == .phone ? 2 : 3
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: Wisper.Space.l) {
        configuration.label
          .frame(maxWidth: .infinity, alignment: .leading)
        Capsule()
          .fill(configuration.isOn ? Wisper.Color.inverse : Wisper.Color.track)
          .frame(width: width, height: height)
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle()
              .fill(configuration.isOn ? Wisper.Color.onInverse : Wisper.Color.knob)
              .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
              .padding(inset)
          }
          .animation(Wisper.Motion.smooth, value: configuration.isOn)
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
///       Button("Change") { ... }.buttonStyle(.wisper())
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
    HStack(alignment: .center, spacing: Wisper.Space.l) {
      SettingText(title: title, description: description)
        .frame(maxWidth: .infinity, alignment: .leading)
      control
    }
    .padding(.horizontal, 20)
    .padding(.vertical, Wisper.Space.l)
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
    .toggleStyle(.wisper)
    .padding(.horizontal, 20)
    .padding(.vertical, Wisper.Space.l)
    .frame(minHeight: 64)
  }
}

private struct SettingText: View {
  let title: String
  let description: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Wisper.Space.xs) {
      Text(title).wisperText(.bodyStrong)
      if let description {
        Text(description)
          .wisperText(.caption)
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

  @Environment(\.wisperIdiom) private var idiom

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
    HStack(spacing: Wisper.Space.m) {
      Text(title(selection))
        .wisperText(.body)
        .lineLimit(1)
      Spacer(minLength: 0)
      Image(systemName: "chevron.down")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Wisper.Color.textSecondary)
    }
  }
}

private struct DropdownButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    DropdownBox { configuration.label }
  }
}

/// The white, bordered box of a select box.
private struct DropdownBox<Label: View>: View {
  @ViewBuilder let label: Label
  @Environment(\.wisperIdiom) private var idiom
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.control, style: .continuous)
    label
      .padding(.horizontal, Wisper.Space.m)
      .frame(minHeight: idiom == .phone ? 44 : 36)
      .background(isHovered ? Wisper.Color.surface : Wisper.Color.raised, in: shape)
      .overlay { shape.strokeBorder(Wisper.Color.borderStrong, lineWidth: Wisper.Stroke.hairline) }
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(shape)
      .onHover { isHovered = $0 }
      .animation(Wisper.Motion.quick, value: isHovered)
  }
}

/// How `Tabs` are drawn.
public enum TabsStyle: Sendable {
  /// Text tabs on a hairline, the current one underlined. For the top of a page.
  case underline
  /// A compact box of segments. For a choice inside a card or on iPhone.
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
  @Environment(\.wisperIdiom) private var idiom

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
    HStack(alignment: .bottom, spacing: Wisper.Space.xl) {
      ForEach(options, id: \.self) { option in
        let isSelected = option == selection
        Button {
          withAnimation(Wisper.Motion.smooth) { selection = option }
        } label: {
          Text(title(option))
            .wisperText(.bodyStrong, color: isSelected ? Wisper.Color.textPrimary : Wisper.Color.textSecondary)
            .lineLimit(1)
            .padding(.bottom, Wisper.Space.m)
            .overlay(alignment: .bottom) {
              if isSelected {
                Rectangle()
                  .fill(Wisper.Color.textPrimary)
                  .frame(height: 2)
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
      HStack(spacing: Wisper.Space.xs) { trailing }
        .padding(.bottom, Wisper.Space.xs)
    }
    .overlay(alignment: .bottom) { Hairline() }
  }

  private var segmented: some View {
    HStack(spacing: Wisper.Space.xxs) {
      ForEach(options, id: \.self) { option in
        let isSelected = option == selection
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button {
          withAnimation(Wisper.Motion.smooth) { selection = option }
        } label: {
          Text(title(option))
            .wisperText(.captionStrong, color: isSelected ? Wisper.Color.textPrimary : Wisper.Color.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: idiom == .phone ? 36 : 30)
            .background {
              if isSelected {
                shape
                  .fill(Wisper.Color.segment)
                  .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                  .matchedGeometryEffect(id: "segment", in: namespace)
              }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .padding(3)
    .background(Wisper.Color.surfaceSelected, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
  }
}

/// A small pill with a word in it: "New", "Beta", a status.
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
    Text(text)
      .font(.system(size: 11.5, weight: .semibold))
      .foregroundStyle(foreground)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        tone == .neutral ? Wisper.Color.surfaceSelected : foreground.opacity(Self.tintOpacity),
        in: RoundedRectangle(cornerRadius: Wisper.Radius.small, style: .continuous)
      )
  }

  /// How strongly a tone colours its own background.
  nonisolated static let tintOpacity = 0.12

  private var foreground: SwiftUI.Color {
    switch tone {
    case .neutral: Wisper.Color.textSecondary
    case .accent: Wisper.Color.accent
    case .success: Wisper.Color.success
    case .warning: Wisper.Color.warning
    case .danger: Wisper.Color.danger
    }
  }
}
