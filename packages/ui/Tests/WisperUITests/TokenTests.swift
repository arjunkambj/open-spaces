import SwiftUI
import Testing

@testable import WisperUI

/// WCAG relative luminance of an opaque colour.
private func luminance(_ value: ColorPair.Value) -> Double {
  func linear(_ channel: Double) -> Double {
    channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * linear(value.red) + 0.7152 * linear(value.green) + 0.0722 * linear(value.blue)
}

private func contrast(_ a: ColorPair.Value, _ b: ColorPair.Value) -> Double {
  let (light, dark) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
  return (light + 0.05) / (dark + 0.05)
}

/// `top` at `opacity` laid over `bottom`.
private func blend(_ top: ColorPair.Value, over bottom: ColorPair.Value, opacity: Double) -> ColorPair.Value {
  func mix(_ a: Double, _ b: Double) -> UInt32 { UInt32((a * opacity + b * (1 - opacity)) * 255 + 0.5) }
  let hex =
    mix(top.red, bottom.red) << 16 | mix(top.green, bottom.green) << 8 | mix(top.blue, bottom.blue)
  return ColorPair.Value(hex: hex)
}

private typealias Palette = Wisper.Palette
private let schemes: [ColorScheme] = [.light, .dark]

@Test func readingTextHasEnoughContrastOnEverySurface() {
  let texts = ["textPrimary": Palette.textPrimary, "textSecondary": Palette.textSecondary]
  let surfaces = [
    "window": Palette.window, "panel": Palette.panel, "surface": Palette.surface,
    "surfaceHover": Palette.surfaceHover, "surfaceSelected": Palette.surfaceSelected,
    "raised": Palette.raised,
  ]
  for scheme in schemes {
    for (textName, text) in texts {
      for (surfaceName, surface) in surfaces {
        let ratio = contrast(text.value(scheme), surface.value(scheme))
        #expect(ratio >= 4.5, "\(textName) on \(surfaceName), \(scheme): \(ratio)")
      }
    }
  }
}

@Test func quietTextAndSignalColoursAreReadableWhereTheyAreUsed() {
  let texts = [
    "textTertiary": Palette.textTertiary, "accent": Palette.accent, "success": Palette.success,
    "warning": Palette.warning, "danger": Palette.danger,
  ]
  let surfaces = [
    "window": Palette.window, "panel": Palette.panel, "surface": Palette.surface, "raised": Palette.raised,
  ]
  for scheme in schemes {
    for (textName, text) in texts {
      for (surfaceName, surface) in surfaces {
        let ratio = contrast(text.value(scheme), surface.value(scheme))
        #expect(ratio >= 4.5, "\(textName) on \(surfaceName), \(scheme): \(ratio)")
      }
    }
  }
}

@Test func textOnFilledControlsIsReadable() {
  let pairs = [
    ("onInverse on inverse", Palette.onInverse, Palette.inverse),
    ("onAccent on accent", Palette.onAccent, Palette.accent),
    ("onDanger on danger", Palette.onDanger, Palette.danger),
    ("textPrimary on segment", Palette.textPrimary, Palette.segment),
  ]
  for scheme in schemes {
    for (name, text, fill) in pairs {
      let ratio = contrast(text.value(scheme), fill.value(scheme))
      #expect(ratio >= 4.5, "\(name), \(scheme): \(ratio)")
    }
  }
}

@Test func badgeTextIsReadableOnItsTint() {
  let tones = [
    "accent": Palette.accent, "success": Palette.success, "warning": Palette.warning,
    "danger": Palette.danger,
  ]
  let surfaces = ["window": Palette.window, "panel": Palette.panel, "surface": Palette.surface]
  for scheme in schemes {
    for (toneName, tone) in tones {
      for (surfaceName, surface) in surfaces {
        let tint = blend(tone.value(scheme), over: surface.value(scheme), opacity: Badge.tintOpacity)
        let ratio = contrast(tone.value(scheme), tint)
        #expect(ratio >= 4.5, "\(toneName) badge on \(surfaceName), \(scheme): \(ratio)")
      }
    }
    let neutral = contrast(Palette.textSecondary.value(scheme), Palette.surfaceSelected.value(scheme))
    #expect(neutral >= 4.5, "neutral badge, \(scheme): \(neutral)")
  }
}

@Test func surfacesStepApartSoLayersCanBeTold() {
  for scheme in schemes {
    let window = luminance(Palette.window.value(scheme))
    let panel = luminance(Palette.panel.value(scheme))
    let surface = luminance(Palette.surface.value(scheme))
    let hover = luminance(Palette.surfaceHover.value(scheme))
    let selected = luminance(Palette.surfaceSelected.value(scheme))
    #expect(panel > window, "the panel is lighter than the window, \(scheme)")
    if scheme == .light {
      #expect(surface > hover && hover > selected)
    } else {
      #expect(surface < hover && hover < selected)
    }
  }
}

@Test func textStylesAreLargerOnPhoneAndSerifWhereMeant() {
  for style in Wisper.TextStyle.allCases {
    let mac = style.metrics(.mac)
    let phone = style.metrics(.phone)
    #expect(mac.size >= 11, "\(style) is too small to read")
    #expect(phone.size >= mac.size || style == .hero, "\(style) shrinks on iPhone")
  }
  #expect(Wisper.TextStyle.statNumber.metrics(.mac).design == .serif)
  #expect(Wisper.TextStyle.hero.metrics(.phone).design == .serif)
  #expect(Wisper.TextStyle.mono.metrics(.mac).design == .monospaced)
  #expect(Wisper.TextStyle.sectionLabel.metrics(.mac).uppercase)
}

@Test func waveformBarsStayInsideTheirHeight() {
  for level in [0.0, 0.1, 0.5, 1.0] {
    for time in stride(from: 0.0, to: 3.0, by: 0.137) {
      for index in 0..<9 {
        let height = Waveform.barHeight(index, of: 9, level: level, time: time, max: 20)
        #expect(height >= 2 && height <= 20)
        if level == 0 { #expect(height < 4, "silence rests as dots") }
      }
    }
  }
  let loud = (0..<9).map { Waveform.barHeight($0, of: 9, level: 1, time: 1, max: 20) }.max() ?? 0
  let quiet = (0..<9).map { Waveform.barHeight($0, of: 9, level: 0.1, time: 1, max: 20) }.max() ?? 0
  #expect(loud > quiet)
}
