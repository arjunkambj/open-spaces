import AppKit
import SwiftUI

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
  }
}

extension Spaces {
  /// The raw values behind `Spaces.Color`.
  ///
  /// Black and white with a neutral grey ramp, no hue. In light mode: 0 `FFFFFF`, 25 `FAFAFA`,
  /// 50 `F5F5F5`, 100 `EDEDED`, 150 `E3E3E3`, 200 `D4D4D4`, 400 `8F8F8F`, 500 `5D5D5D`,
  /// 600 `454545`, 900 `1A1A1A`, 1000 `0D0D0D`. Dark mode runs the other way, from `0D0D0D`
  /// up to `ECECEC`. Keep new greys on that ramp. The only hue is red, for errors, deleting
  /// and a live recording.
  enum Palette {
    static let window = ColorPair(light: 0xF5F5F5, dark: 0x0D0D0D)
    static let panel = ColorPair(light: 0xFFFFFF, dark: 0x171717)
    static let surface = ColorPair(light: 0xF5F5F5, dark: 0x262626)
    static let surfaceHover = ColorPair(light: 0xEDEDED, dark: 0x2E2E2E)
    static let surfaceSelected = ColorPair(light: 0xE3E3E3, dark: 0x383838)
    static let raised = ColorPair(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let border = ColorPair(
      light: .init(hex: 0x0D0D0D, alpha: 0.09),
      dark: .init(hex: 0xFFFFFF, alpha: 0.10)
    )
    static let borderStrong = ColorPair(
      light: .init(hex: 0x0D0D0D, alpha: 0.16),
      dark: .init(hex: 0xFFFFFF, alpha: 0.20)
    )
    static let textPrimary = ColorPair(light: 0x0D0D0D, dark: 0xECECEC)
    static let textSecondary = ColorPair(light: 0x5D5D5D, dark: 0xB4B4B4)
    static let textTertiary = ColorPair(light: 0x737373, dark: 0x8F8F8F)
    static let inverse = ColorPair(light: 0x0D0D0D, dark: 0xFFFFFF)
    static let onInverse = ColorPair(light: 0xFFFFFF, dark: 0x0D0D0D)
    static let danger = ColorPair(light: 0xD92D20, dark: 0xFF6B60)
    static let onDanger = ColorPair(light: 0xFFFFFF, dark: 0x1A0605)
    static let recording = ColorPair(light: 0xE5332A, dark: 0xFF5A50)
    static let scrim = ColorPair(
      light: .init(hex: 0x0D0D0D, alpha: 0.32),
      dark: .init(hex: 0x000000, alpha: 0.60)
    )
    static let track = ColorPair(light: 0xD4D4D4, dark: 0x454545)
    static let knob = ColorPair(light: 0xFFFFFF, dark: 0xD4D4D4)
    static let segment = ColorPair(light: 0xFFFFFF, dark: 0x4A4A4A)
  }

  /// Semantic colours. Each follows light and dark mode by itself.
  ///
  /// The look is black and white: `accent` is near-black in light mode and white in dark mode,
  /// and `success` and `warning` are ink too, so the symbol beside them carries the meaning.
  /// Red is kept for errors, deleting and a live recording.
  public enum Color {
    /// The window behind everything; the sidebar sits right on it.
    public static let window = Palette.window.color
    /// The large content panel.
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
    /// Placeholders and timestamps. Readable on window, panel and raised; on a card, prefer
    /// `textSecondary` for anything that must be read.
    public static let textTertiary = Palette.textTertiary.color
    /// The near-black fill of primary buttons and the floating pill (white in dark mode).
    public static let inverse = Palette.inverse.color
    /// Text and icons on `inverse`.
    public static let onInverse = Palette.onInverse.color
    /// The ink that marks what is chosen or live: near-black, or white in dark mode.
    public static let accent = Palette.inverse.color
    /// Text and icons on `accent`.
    public static let onAccent = Palette.onInverse.color
    /// Something worked. Ink, with a check mark beside it.
    public static let success = Palette.textPrimary.color
    /// Something needs attention. Ink, with a warning sign beside it.
    public static let warning = Palette.textPrimary.color
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
