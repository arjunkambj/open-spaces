import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// The Spaces design tokens: `Spaces.Color`, `Spaces.TextStyle`, `Spaces.Space`,
/// `Spaces.Radius`, `Spaces.Stroke` and `Spaces.Motion`.
///
/// Screens take every colour, font, gap and corner from here. See `COMPONENTS.md`.
public enum Spaces {
  /// The kind of device a view is laid out for.
  ///
  /// Components read it from the environment (`\.spacesIdiom`) to pick sizes and layouts.
  /// It follows the platform by default; the snapshot renderer sets `.phone` on phone canvases.
  public enum Idiom: Sendable, Equatable {
    /// A Mac: pointer, hover, dense rows.
    case mac
    /// An iPhone or iPad: touch, larger text and targets.
    case phone

    /// The idiom of the platform this code was built for.
    public static var current: Idiom {
      #if os(iOS)
        .phone
      #else
        .mac
      #endif
    }
  }

  /// Gaps and paddings, in points. Everything sits on a 4-point grid.
  public enum Space {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
  }

  /// Corner radii, in points. Buttons, the switch and the segmented control are capsules,
  /// whatever their height; they need no radius.
  public enum Radius {
    /// Key caps, badges.
    public static let small: CGFloat = 6
    /// Fields, select boxes, menus and rows.
    public static let control: CGFloat = 10
    /// Cards and banners.
    public static let card: CGFloat = 16
    /// The hub's content panel and dialogs.
    public static let panel: CGFloat = 24
  }

  /// Line widths, in points.
  public enum Stroke {
    /// Borders and dividers.
    public static let hairline: CGFloat = 1
    /// The border of a focused field.
    public static let focus: CGFloat = 1.5
  }

  /// Animation presets. Each one turns into a short fade when Reduce Motion is on.
  @MainActor
  public enum Motion {
    /// Hover and press feedback.
    public static var quick: Animation { .easeOut(duration: reduceMotion ? 0.01 : 0.12) }
    /// Things that change size or place inside a screen: tabs, the search field, a toast.
    public static var smooth: Animation {
      reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.86)
    }
    /// Presenting dialogs and changing the shape of the floating pill.
    public static var spring: Animation {
      reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.8)
    }

    /// Whether the person asked the system for less motion.
    public static var reduceMotion: Bool {
      #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      #elseif canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
      #else
        false
      #endif
    }
  }
}

private struct IdiomKey: EnvironmentKey {
  static let defaultValue = Spaces.Idiom.current
}

/// Forces the hover look, so the component gallery can show it in a still image.
private struct SimulatedHoverKey: EnvironmentKey {
  static let defaultValue = false
}

/// Forces the focused look of fields, for the same reason.
private struct SimulatedFocusKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// The kind of device the view is laid out for. See `Spaces.Idiom`.
  public var spacesIdiom: Spaces.Idiom {
    get { self[IdiomKey.self] }
    set { self[IdiomKey.self] = newValue }
  }

  var simulatedHover: Bool {
    get { self[SimulatedHoverKey.self] }
    set { self[SimulatedHoverKey.self] = newValue }
  }

  var simulatedFocus: Bool {
    get { self[SimulatedFocusKey.self] }
    set { self[SimulatedFocusKey.self] = newValue }
  }
}
