import SwiftUI

/// The button looks of Spaces. Use it as `.buttonStyle(.spaces(.primary))`.
public struct SpacesButtonStyle: ButtonStyle {
  public enum Kind: Sendable {
    /// The one main action of a screen or dialog: near-black fill (white in dark mode).
    case primary
    /// Normal actions: light grey fill.
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
  /// A Spaces button: a capsule.
  /// - fullWidth: stretches the button to the width it is given.
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
  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false

  var body: some View {
    let shape = PillShape()
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
      .contentShape(.focusEffect, shape)
      .onHover { isHovered = $0 }
      .animation(Spaces.Motion.quick, value: isHovered)
      .animation(Spaces.Motion.quick, value: configuration.isPressed)
  }

  private var height: CGFloat {
    switch size {
    case .regular: 36
    case .small: 28
    }
  }

  private var horizontalPadding: CGFloat {
    switch size {
    case .regular: 18
    case .small: 12
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

/// A capsule: a rectangle with fully round ends. The kit draws buttons, the search field and
/// segments with it: a stroked system `Capsule` can show stray lines beside its ends.
struct PillShape: InsettableShape {
  private var inset: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    let box = rect.insetBy(dx: inset, dy: inset)
    let radius = min(box.width, box.height) / 2
    // Drawn arc by arc: a path made as a rounded rectangle is drawn the same way as `Capsule`.
    var path = Path()
    path.move(to: CGPoint(x: box.minX + radius, y: box.minY))
    path.addLine(to: CGPoint(x: box.maxX - radius, y: box.minY))
    path.addArc(
      center: CGPoint(x: box.maxX - radius, y: box.minY + radius),
      radius: radius,
      startAngle: .degrees(-90),
      endAngle: .degrees(0),
      clockwise: false
    )
    path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - radius))
    path.addArc(
      center: CGPoint(x: box.maxX - radius, y: box.maxY - radius),
      radius: radius,
      startAngle: .degrees(0),
      endAngle: .degrees(90),
      clockwise: false
    )
    path.addLine(to: CGPoint(x: box.minX + radius, y: box.maxY))
    path.addArc(
      center: CGPoint(x: box.minX + radius, y: box.maxY - radius),
      radius: radius,
      startAngle: .degrees(90),
      endAngle: .degrees(180),
      clockwise: false
    )
    path.addLine(to: CGPoint(x: box.minX, y: box.minY + radius))
    path.addArc(
      center: CGPoint(x: box.minX + radius, y: box.minY + radius),
      radius: radius,
      startAngle: .degrees(180),
      endAngle: .degrees(270),
      clockwise: false
    )
    path.closeSubpath()
    return path
  }

  func inset(by amount: CGFloat) -> PillShape {
    var shape = self
    shape.inset += amount
    return shape
  }
}

/// The round look shared by `IconButton` and `OverflowMenu`.
struct IconButtonStyle: ButtonStyle {
  var size: SpacesButtonStyle.Size = .regular

  func makeBody(configuration: Configuration) -> some View {
    IconChrome(size: size, isPressed: configuration.isPressed) { configuration.label }
  }
}

/// The round, hover-highlighted spot an icon sits in.
struct IconChrome<Label: View>: View {
  var size: SpacesButtonStyle.Size = .regular
  var isPressed = false
  @ViewBuilder let label: Label

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false

  var body: some View {
    let hovered = (isHovered || simulatedHover) && isEnabled
    let shape = Circle()
    label
      .font(.system(size: glyphSize, weight: .regular))
      .foregroundStyle(hovered ? Spaces.Color.textPrimary : Spaces.Color.textSecondary)
      .frame(width: side, height: side)
      .background(background(hovered: hovered), in: shape)
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(shape)
      .contentShape(.focusEffect, shape)
      .onHover { isHovered = $0 }
      .animation(Spaces.Motion.quick, value: isHovered)
  }

  private var side: CGFloat {
    switch size {
    case .regular: 32
    case .small: 26
    }
  }

  private var glyphSize: CGFloat {
    switch size {
    case .regular: 15
    case .small: 12
    }
  }

  private func background(hovered: Bool) -> SwiftUI.Color {
    if isPressed { return Spaces.Color.surfaceSelected }
    return hovered ? Spaces.Color.surfaceHover : .clear
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

  // The Mac draws a menu's label as a system button unless it is given a button style.
  private var menu: some View {
    Menu {
      items
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuStyle(.button)
    .buttonStyle(IconButtonStyle())
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
  /// Puts a soft grey rounded rectangle behind the view while the pointer is over it,
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
          .font(.system(size: 15, weight: isSelected ? .medium : .regular))
          .foregroundStyle(isSelected ? Spaces.Color.textPrimary : Spaces.Color.textSecondary)
          .frame(width: 22)
        Text(title).spacesText(isSelected ? .bodyStrong : .body)
        Spacer(minLength: Spaces.Space.s)
        if let badge { Badge(badge, tone: .accent) }
      }
      .padding(.horizontal, Spaces.Space.m)
      .frame(minHeight: 36)
      .hoverHighlight(isSelected: isSelected)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
