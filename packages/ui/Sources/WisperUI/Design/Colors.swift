import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// One colour with its light and dark value, as `0xRRGGBB` plus an opacity.
struct ColorPair: Sendable, Equatable {
  struct Value: Sendable, Equatable {
    var hex: UInt32
    var alpha: Double = 1

    var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    var blue: Double { Double(hex & 0xFF) / 255 }
  }

  var light: Value
  var dark: Value

  init(light: UInt32, dark: UInt32) {
    self.light = Value(hex: light)
    self.dark = Value(hex: dark)
  }

  init(light: Value, dark: Value) {
    self.light = light
    self.dark = dark
  }

  func value(_ scheme: ColorScheme) -> Value { scheme == .dark ? dark : light }

  /// A colour that follows the light or dark appearance by itself. No asset catalog needed.
  var color: SwiftUI.Color {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
      let spec = self
      return SwiftUI.Color(
        nsColor: NSColor(name: nil) { appearance in
          let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          let value = isDark ? spec.dark : spec.light
          return NSColor(
            srgbRed: value.red,
            green: value.green,
            blue: value.blue,
            alpha: value.alpha
          )
        }
      )
    #elseif canImport(UIKit)
      let spec = self
      return SwiftUI.Color(
        uiColor: UIColor { traits in
          let value = traits.userInterfaceStyle == .dark ? spec.dark : spec.light
          return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
        }
      )
    #else
      return SwiftUI.Color(.sRGB, red: light.red, green: light.green, blue: light.blue, opacity: light.alpha)
    #endif
  }
}

extension Wisper {
  /// The raw values behind `Wisper.Color`. Tests check their contrast.
  enum Palette {
    static let window = ColorPair(light: 0xF4F3F0, dark: 0x161513)
    static let panel = ColorPair(light: 0xFBFAF8, dark: 0x1D1C19)
    static let surface = ColorPair(light: 0xF3F2EE, dark: 0x262521)
    static let surfaceHover = ColorPair(light: 0xEEECE7, dark: 0x2D2C27)
    static let surfaceSelected = ColorPair(light: 0xE6E3DC, dark: 0x383632)
    static let raised = ColorPair(light: 0xFFFFFF, dark: 0x2C2B27)
    static let border = ColorPair(
      light: .init(hex: 0x1C1B19, alpha: 0.10),
      dark: .init(hex: 0xF2F0EB, alpha: 0.10)
    )
    static let borderStrong = ColorPair(
      light: .init(hex: 0x1C1B19, alpha: 0.20),
      dark: .init(hex: 0xF2F0EB, alpha: 0.22)
    )
    static let textPrimary = ColorPair(light: 0x1C1B19, dark: 0xF2F0EB)
    static let textSecondary = ColorPair(light: 0x5C5952, dark: 0xB8B4AB)
    static let textTertiary = ColorPair(light: 0x6E6A63, dark: 0x9C988F)
    static let inverse = ColorPair(light: 0x1C1B19, dark: 0xF2F0EB)
    static let onInverse = ColorPair(light: 0xFFFFFF, dark: 0x1C1B19)
    static let accent = ColorPair(light: 0x1F6A4D, dark: 0x79D2A8)
    static let onAccent = ColorPair(light: 0xFFFFFF, dark: 0x0E2018)
    static let success = ColorPair(light: 0x236B37, dark: 0x82D694)
    static let warning = ColorPair(light: 0x7C5100, dark: 0xEBB95A)
    static let danger = ColorPair(light: 0xAB2D22, dark: 0xFF8F80)
    static let onDanger = ColorPair(light: 0xFFFFFF, dark: 0x2B0D09)
    static let recording = ColorPair(light: 0xE0443E, dark: 0xFF5F57)
    static let scrim = ColorPair(
      light: .init(hex: 0x1C1B19, alpha: 0.36),
      dark: .init(hex: 0x000000, alpha: 0.56)
    )
    static let track = ColorPair(light: 0xD5D1C8, dark: 0x4B4943)
    static let knob = ColorPair(light: 0xFFFFFF, dark: 0xE9E6DF)
    static let segment = ColorPair(light: 0xFFFFFF, dark: 0x55524C)
  }

  /// Semantic colours. Each follows light and dark mode by itself.
  public enum Color {
    /// The window behind everything; the sidebar sits right on it.
    public static let window = Palette.window.color
    /// The large content panel, and the page background on iPhone.
    public static let panel = Palette.panel.color
    /// Cards and rows.
    public static let surface = Palette.surface.color
    /// A row or control under the pointer.
    public static let surfaceHover = Palette.surfaceHover.color
    /// The selected item in a list or sidebar, and the fill of secondary buttons.
    public static let surfaceSelected = Palette.surfaceSelected.color
    /// Things that sit above a card: fields, menus, dialogs.
    public static let raised = Palette.raised.color
    /// Hairline borders and dividers.
    public static let border = Palette.border.color
    /// The border of fields and other controls you type or choose in.
    public static let borderStrong = Palette.borderStrong.color
    /// Titles and body text.
    public static let textPrimary = Palette.textPrimary.color
    /// Helper text and labels.
    public static let textSecondary = Palette.textSecondary.color
    /// Placeholders and timestamps. Readable on window, panel, surface and raised only.
    public static let textTertiary = Palette.textTertiary.color
    /// The near-black fill of primary buttons and the floating pill (near-white in dark mode).
    public static let inverse = Palette.inverse.color
    /// Text and icons on `inverse`.
    public static let onInverse = Palette.onInverse.color
    /// The one accent colour, a deep pine green. Use it sparingly.
    public static let accent = Palette.accent.color
    /// Text and icons on `accent`.
    public static let onAccent = Palette.onAccent.color
    /// Something worked.
    public static let success = Palette.success.color
    /// Something needs attention.
    public static let warning = Palette.warning.color
    /// Errors and destructive actions.
    public static let danger = Palette.danger.color
    /// Text and icons on `danger`.
    public static let onDanger = Palette.onDanger.color
    /// The red of a live recording.
    public static let recording = Palette.recording.color
    /// The dim layer behind a dialog.
    public static let scrim = Palette.scrim.color

    static let track = Palette.track.color
    static let knob = Palette.knob.color
    static let segment = Palette.segment.color
  }
}
