import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// One colour with its light and dark value, as `0xRRGGBB` plus an opacity.
struct ColorPair: Sendable {
  struct Value: Sendable {
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
  /// The raw values behind `Wisper.Color`.
  ///
  /// The greys are the "stone" scale (a warm grey: 50 `FAFAF9`, 100 `F5F5F4`, 200 `E7E5E4`,
  /// 300 `D6D3D1`, 400 `A8A29E`, 500 `78716C`, 600 `57534E`, 700 `44403C`, 800 `292524`,
  /// 900 `1C1917`, 950 `0C0A09`). Keep new greys on that scale, or between two of its steps.
  enum Palette {
    static let window = ColorPair(light: 0xF5F5F4, dark: 0x0C0A09)
    static let panel = ColorPair(light: 0xFAFAF9, dark: 0x1C1917)
    static let surface = ColorPair(light: 0xF5F5F4, dark: 0x292524)
    static let surfaceHover = ColorPair(light: 0xEEEDEC, dark: 0x363230)
    static let surfaceSelected = ColorPair(light: 0xE7E5E4, dark: 0x44403C)
    static let raised = ColorPair(light: 0xFFFFFF, dark: 0x292524)
    static let border = ColorPair(
      light: .init(hex: 0x1C1917, alpha: 0.10),
      dark: .init(hex: 0xF5F5F4, alpha: 0.10)
    )
    static let borderStrong = ColorPair(
      light: .init(hex: 0x1C1917, alpha: 0.20),
      dark: .init(hex: 0xF5F5F4, alpha: 0.22)
    )
    static let textPrimary = ColorPair(light: 0x1C1917, dark: 0xF5F5F4)
    static let textSecondary = ColorPair(light: 0x57534E, dark: 0xD6D3D1)
    static let textTertiary = ColorPair(light: 0x6B6560, dark: 0xA8A29E)
    static let inverse = ColorPair(light: 0x1C1917, dark: 0xF5F5F4)
    static let onInverse = ColorPair(light: 0xFFFFFF, dark: 0x1C1917)
    static let accent = ColorPair(light: 0x1F6A4D, dark: 0x79D2A8)
    static let onAccent = ColorPair(light: 0xFFFFFF, dark: 0x0E2018)
    static let success = ColorPair(light: 0x236B37, dark: 0x82D694)
    static let warning = ColorPair(light: 0x7C5100, dark: 0xEBB95A)
    static let danger = ColorPair(light: 0xAB2D22, dark: 0xFF8F80)
    static let onDanger = ColorPair(light: 0xFFFFFF, dark: 0x2B0D09)
    static let recording = ColorPair(light: 0xE0443E, dark: 0xFF5F57)
    static let scrim = ColorPair(
      light: .init(hex: 0x1C1917, alpha: 0.36),
      dark: .init(hex: 0x000000, alpha: 0.56)
    )
    static let track = ColorPair(light: 0xD6D3D1, dark: 0x57534E)
    static let knob = ColorPair(light: 0xFFFFFF, dark: 0xE7E5E4)
    static let segment = ColorPair(light: 0xFFFFFF, dark: 0x57534E)
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
