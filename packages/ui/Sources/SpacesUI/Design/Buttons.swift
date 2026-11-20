import SwiftUI

/// The button looks of Spaces. Use it as `.buttonStyle(.spaces(.primary))`.
public struct SpacesButtonStyle: ButtonStyle {
  public enum Kind: Sendable {
    /// The one main action of a screen or dialog: near-black fill.
    case primary
    /// Normal actions: warm-grey fill.
    case secondary
    /// Quiet actions next to other content: white with a hairline border.
    case tertiary
    /// Text only, with a highlight under the pointer.
    case ghost
    /// Deletes or throws something away: red fill.
    case destructive
  }

  public enum Size: Sendable {
    case regular
    case small
  }

  let kind: Kind
  let size: Size
  let fullWidth: Bool

  public func makeBody(configuration: Configuration) -> some View {
    ButtonBody(configuration: configuration, kind: kind, size: size, fullWidth: fullWidth)
  }
}

extension ButtonStyle where Self == SpacesButtonStyle {
  /// An Spaces button.
  /// - fullWidth: stretches the button to the width it is given (bottom-of-screen actions on iPhone).
  public static func spaces(
    _ kind: SpacesButtonStyle.Kind = .secondary,
    size: SpacesButtonStyle.Size = .regular,
    fullWidth: Bool = false
  ) -> SpacesButtonStyle {
    SpacesButtonStyle(kind: kind, size: size, fullWidth: fullWidth)
  }
}

private struct ButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: SpacesButtonStyle.Kind
  let size: SpacesButtonStyle.Size
  let fullWidth: Bool

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.spacesIdiom) private var idiom
  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    configuration.label
      .labelStyle(ButtonLabelStyle())
      .spacesText(size == .regular ? .bodyStrong : .captionStrong, color: foreground)
      .lineLimit(1)
      .padding(.horizontal, horizontalPadding)
      .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
      .background(fill, in: shape)
      .overlay { shape.fill(stateTint.opacity(stateOpacity)) }
      .overlay { shape.strokeBorder(border, lineWidth: Spaces.Stroke.hairline) }
      .opacity(isEnabled ? 1 : 0.42)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .contentShape(shape)
      .focusRingShape(shape)
      .frame(minHeight: idiom == .phone ? 44 : nil)
      .onHover { isHovered = $0 }
      .animation(Spaces.Motion.quick, value: isHovered)
      .animation(Spaces.Motion.quick, value: configuration.isPressed)
  }

  private var height: CGFloat {
    switch (idiom, size) {
    case (.mac, .regular): 36
    case (.mac, .small): 28
    case (.phone, .regular): 50
    case (.phone, .small): 36
    }
  }

  private var horizontalPadding: CGFloat {
    switch (idiom, size) {
    case (.mac, .regular): 16
    case (.mac, .small): 11
    case (.phone, .regular): 20
    case (.phone, .small): 14
    }
  }

  private var radius: CGFloat {
    switch (idiom, size) {
    case (.mac, .regular): Spaces.Radius.control
    case (.mac, .small): 8
    case (.phone, .regular): 14
    case (.phone, .small): Spaces.Radius.control
    }
  }

  private var fill: SwiftUI.Color {
    switch kind {
    case .primary: Spaces.Color.inverse
    case .secondary: Spaces.Color.surfaceSelected
    case .tertiary: Spaces.Color.raised
    case .ghost: .clear
    case .destructive: Spaces.Color.danger
    }
  }

  private var foreground: SwiftUI.Color {
    switch kind {
    case .primary: Spaces.Color.onInverse
    case .destructive: Spaces.Color.onDanger
    case .secondary, .tertiary, .ghost: Spaces.Color.textPrimary
    }
  }

  private var border: SwiftUI.Color {
    kind == .tertiary ? Spaces.Color.borderStrong : .clear
  }

  /// The colour laid over the fill while hovered or pressed.
  private var stateTint: SwiftUI.Color {
    switch kind {
    case .primary: Spaces.Color.onInverse
    case .destructive: Spaces.Color.onDanger
    case .secondary, .tertiary, .ghost: Spaces.Color.textPrimary
    }
  }

  private var stateOpacity: Double {
    let strong = kind == .primary || kind == .destructive
    if configuration.isPressed { return strong ? 0.24 : 0.11 }
    if (isHovered || simulatedHover) && isEnabled { return strong ? 0.14 : 0.06 }
    return 0
  }
}

/// Icon and title side by side, with the gap buttons use.
private struct ButtonLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon
      configuration.title
    }
  }
}

/// The square look shared by `IconButton` and `OverflowMenu`.
struct IconButtonStyle: ButtonStyle {
  var size: SpacesButtonStyle.Size = .regular

  func makeBody(configuration: Configuration) -> some View {
    IconChrome(size: size, isPressed: configuration.isPressed) { configuration.label }
  }
}

/// The square, hover-highlighted box an icon sits in.
struct IconChrome<Label: View>: View {
  var size: SpacesButtonStyle.Size = .regular
  var isPressed = false
  @ViewBuilder let label: Label

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.spacesIdiom) private var idiom
  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false

  var body: some View {
    let hovered = (isHovered || simulatedHover) && isEnabled
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    label
      .font(.system(size: glyphSize, weight: .medium))
      .foregroundStyle(hovered ? Spaces.Color.textPrimary : Spaces.Color.textSecondary)
      .frame(width: side, height: side)
      .background(background(hovered: hovered), in: shape)
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(shape)
      .focusRingShape(shape)
      .frame(minWidth: idiom == .phone ? 44 : nil, minHeight: idiom == .phone ? 44 : nil)
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .animation(Spaces.Motion.quick, value: isHovered)
  }

  private var side: CGFloat {
    switch (idiom, size) {
    case (.mac, .regular): 32
    case (.mac, .small): 26
    case (.phone, .regular): 40
    case (.phone, .small): 34
    }
  }

  private var glyphSize: CGFloat {
    switch (idiom, size) {
    case (.mac, .regular): 15
    case (.mac, .small): 12
    case (.phone, .regular): 19
    case (.phone, .small): 15
    }
  }

  private func background(hovered: Bool) -> SwiftUI.Color {
    if isPressed { return Spaces.Color.surfaceSelected }
    return hovered ? Spaces.Color.surfaceHover : .clear
  }
}

extension View {
  /// Makes the keyboard focus ring follow `shape`. The Mac draws the ring; iOS has none.
  func focusRingShape(_ shape: some Shape) -> some View {
    #if os(macOS)
      contentShape(.focusEffect, shape)
    #else
      self
    #endif
  }
}

/// A button that is only an icon. The label is its tooltip and its VoiceOver name.
public struct IconButton: View {
  private let systemName: String
  private let label: String
  private let size: SpacesButtonStyle.Size
  private let action: () -> Void

  /// - systemName: an SF Symbol name.
  /// - label: what the button does, in a word or two, e.g. "Copy".
  public init(
    _ systemName: String,
    label: String,
    size: SpacesButtonStyle.Size = .regular,
    action: @escaping () -> Void
  ) {
    self.systemName = systemName
    self.label = label
    self.size = size
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
    }
    .buttonStyle(IconButtonStyle(size: size))
    .help(label)
    .accessibilityLabel(label)
  }
}

/// The standard "…" button that opens a menu of more actions for a row or a page.
///
///     OverflowMenu {
///       Button("Copy") { ... }
///       Button("Delete", role: .destructive) { ... }
///     }
public struct OverflowMenu<Items: View>: View {
  private let label: String
  private let items: Items

  /// - label: the tooltip and VoiceOver name.
  public init(label: String = "More", @ViewBuilder items: () -> Items) {
    self.label = label
    self.items = items()
  }

  public var body: some View {
    menu
      .menuIndicator(.hidden)
      .fixedSize()
      .help(label)
      .accessibilityLabel(label)
  }

  // The Mac draws a menu's label as a system button unless it is given a button style;
  // iOS draws the label as it is.
  @ViewBuilder private var menu: some View {
    #if os(macOS)
      Menu {
        items
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.button)
      .buttonStyle(IconButtonStyle())
    #else
      Menu {
        items
      } label: {
        IconChrome { Image(systemName: "ellipsis") }
      }
    #endif
  }
}

private struct HoverHighlight: ViewModifier {
  let radius: CGFloat
  let isSelected: Bool
  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .onHover { isHovered = $0 }
      .animation(Spaces.Motion.quick, value: isHovered)
  }

  private var fill: SwiftUI.Color {
    if isSelected { return Spaces.Color.surfaceSelected }
    return isHovered || simulatedHover ? Spaces.Color.surfaceHover : .clear
  }
}

extension View {
  /// Puts a soft warm-grey rounded rectangle behind the view while the pointer is over it,
  /// and a slightly stronger one while `isSelected`.
  public func hoverHighlight(radius: CGFloat = Spaces.Radius.control, isSelected: Bool = false) -> some View {
    modifier(HoverHighlight(radius: radius, isSelected: isSelected))
  }
}

/// One entry of a sidebar or of the settings navigation: icon, label, optional badge.
public struct NavItem: View {
  private let title: String
  private let systemImage: String
  private let isSelected: Bool
  private let badge: String?
  private let action: () -> Void

  @Environment(\.spacesIdiom) private var idiom

  public init(
    _ title: String,
    systemImage: String,
    isSelected: Bool,
    badge: String? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isSelected = isSelected
    self.badge = badge
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: Spaces.Space.m) {
        Image(systemName: systemImage)
          .font(.system(size: idiom == .phone ? 18 : 15, weight: isSelected ? .medium : .regular))
          .foregroundStyle(isSelected ? Spaces.Color.textPrimary : Spaces.Color.textSecondary)
          .frame(width: 22)
        Text(title).spacesText(isSelected ? .bodyStrong : .body)
        Spacer(minLength: Spaces.Space.s)
        if let badge { Badge(badge, tone: .accent) }
      }
      .padding(.horizontal, Spaces.Space.m)
      .frame(minHeight: idiom == .phone ? 48 : 36)
      .hoverHighlight(isSelected: isSelected)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
