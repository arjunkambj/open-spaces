import CoreGraphics
import Foundation
import Observation

/// A screen edge the pill sits against.
public enum PillEdge: String, Codable, Sendable, CaseIterable {
  case bottom, top, left, right

  /// On the left or right edge the pill is drawn upright.
  public var isSide: Bool { self == .left || self == .right }
}

/// Where the pill is docked: an edge, and how far along it.
public struct PillSpot: Codable, Equatable, Sendable {
  public var edge: PillEdge
  /// From 0 to 1 along the part of the edge the pill may use: 0 is the left end of the
  /// bottom and top edges, and the bottom end of the left and right edges.
  public var along: Double

  public init(edge: PillEdge, along: Double) {
    self.edge = edge
    self.along = along
  }

  /// Where the pill is until somebody moves it: the middle of the bottom edge.
  public static let home = PillSpot(edge: .bottom, along: 0.5)
}

/// One display, as far as placing the pill goes. Measured the way macOS measures screens:
/// in points, from the bottom left, with y going up.
public struct PillScreen: Equatable, Sendable {
  /// The whole display.
  public var frame: CGRect
  /// The part the pill may sit in: not under the menu bar, the notch or a Dock that is showing.
  public var usable: CGRect

  /// - visibleFrame: the display without the menu bar and the Dock, as macOS reports it.
  /// - topInset: the height of the notch (or anything else at the top that covers content).
  public init(frame: CGRect, visibleFrame: CGRect, topInset: CGFloat = 0) {
    self.frame = frame
    var usable = visibleFrame.intersection(frame)
    if usable.isNull || usable.isEmpty { usable = frame }
    let ceiling = frame.maxY - max(0, topInset)
    if usable.maxY > ceiling, ceiling > usable.minY { usable.size.height = ceiling - usable.minY }
    self.usable = usable
  }
}

/// Where the pill goes. Pure arithmetic: no screens, windows or pointer are asked, so every
/// rule can be checked with made-up numbers.
///
/// The rules:
/// - A pill that is let go docks to the nearest edge of the usable part of its screen, at
///   the place along that edge where it was dropped. A drop outside the usable part (on the
///   menu bar, on the Dock, off the screen) counts as a drop at the closest point inside.
/// - It never docks closer to a corner than `cornerMargin`, so it is always whole.
/// - While it is dragged, the edge it would dock to only changes once another edge is
///   clearly nearer (`edgeSlack`), so the pill does not flip back and forth along a diagonal.
/// - Its window (`panelFrame`) lies inside the usable part of the screen, so nothing the
///   pill shows can leave the screen or slip under the Dock or the menu bar.
public enum PillPlacement {
  /// The size of the pill's window on the bottom and top edges: room for the widest notice
  /// and for the hint over the pill.
  public static let flatPanel = CGSize(width: 480, height: 170)
  /// The size of the pill's window on the left and right edges: room for the tallest pill
  /// and for a notice beside it.
  public static let sidePanel = CGSize(width: 400, height: 360)
  /// The closest the middle of the pill gets to a corner of the screen.
  public static let cornerMargin: CGFloat = 28
  /// How much nearer another edge must be before a dragged pill turns to it.
  public static let edgeSlack: CGFloat = 24

  // MARK: Click or drag

  /// Whether a press that started at `start` and is now at `point` has become a drag.
  /// While recording the pill is forgiving: a slightly shaky click on Stop is still a click.
  public static func isDrag(from start: CGPoint, to point: CGPoint, isRecording: Bool) -> Bool {
    let slop: CGFloat = isRecording ? 8 : 4
    return hypot(point.x - start.x, point.y - start.y) > slop
  }

  // MARK: Docking

  /// The spot for a pill whose middle is at `point` when it is let go.
  /// - current: the edge shown while dragging; it is kept unless another one is clearly nearer.
  public static func spot(droppedAt point: CGPoint, on screen: PillScreen, from current: PillEdge? = nil)
    -> PillSpot
  {
    let area = screen.usable
    let x = min(max(point.x, area.minX), area.maxX)
    let y = min(max(point.y, area.minY), area.maxY)
    // In this order, so that a drop exactly in a corner picks the bottom or the top.
    let distances: [(PillEdge, CGFloat)] = [
      (.bottom, y - area.minY), (.top, area.maxY - y), (.left, x - area.minX), (.right, area.maxX - x),
    ]
    var nearest = distances[0]
    for candidate in distances.dropFirst() where candidate.1 < nearest.1 { nearest = candidate }
    var edge = nearest.0
    if let current, let kept = distances.first(where: { $0.0 == current }), kept.1 <= nearest.1 + edgeSlack {
      edge = current
    }
    let along =
      edge.isSide
      ? fraction(y, from: area.minY, length: area.height) : fraction(x, from: area.minX, length: area.width)
    return PillSpot(edge: edge, along: along)
  }

  /// The point on the edge of the usable part of the screen where the pill is attached.
  public static func foot(of spot: PillSpot, on screen: PillScreen) -> CGPoint {
    let area = screen.usable
    let along = spot.along.isFinite ? min(max(spot.along, 0), 1) : 0.5
    switch spot.edge {
    case .bottom: return CGPoint(x: place(along, from: area.minX, length: area.width), y: area.minY)
    case .top: return CGPoint(x: place(along, from: area.minX, length: area.width), y: area.maxY)
    case .left: return CGPoint(x: area.minX, y: place(along, from: area.minY, length: area.height))
    case .right: return CGPoint(x: area.maxX, y: place(along, from: area.minY, length: area.height))
    }
  }

  /// The frame of the pill's window for a docked pill: against the pill's edge, around the
  /// pill, and moved along the edge as far as needed to lie inside the usable part of the
  /// screen. (On a screen smaller than the window it is centred on that part instead.)
  public static func panelFrame(for spot: PillSpot, on screen: PillScreen) -> CGRect {
    let foot = foot(of: spot, on: screen)
    let size = spot.edge.isSide ? sidePanel : flatPanel
    var origin: CGPoint
    switch spot.edge {
    case .bottom: origin = CGPoint(x: foot.x - size.width / 2, y: foot.y)
    case .top: origin = CGPoint(x: foot.x - size.width / 2, y: foot.y - size.height)
    case .left: origin = CGPoint(x: foot.x, y: foot.y - size.height / 2)
    case .right: origin = CGPoint(x: foot.x - size.width, y: foot.y - size.height / 2)
    }
    if spot.edge.isSide {
      origin.y = fit(origin.y, length: size.height, into: screen.usable.minY, screen.usable.height)
    } else {
      origin.x = fit(origin.x, length: size.width, into: screen.usable.minX, screen.usable.width)
    }
    return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
  }

  /// A point on the screen, measured the way a view in the window `panel` measures: from
  /// the window's top left, with y going down.
  public static func viewPoint(_ point: CGPoint, in panel: CGRect) -> CGPoint {
    CGPoint(x: point.x - panel.minX, y: panel.maxY - point.y)
  }

  /// The screen a point belongs to: the one it is on, or else the nearest one.
  public static func screen(for point: CGPoint, among screens: [PillScreen]) -> Int? {
    if let inside = screens.firstIndex(where: { $0.frame.contains(point) }) { return inside }
    func gap(_ frame: CGRect) -> CGFloat {
      let x = max(frame.minX - point.x, 0, point.x - frame.maxX)
      let y = max(frame.minY - point.y, 0, point.y - frame.maxY)
      return hypot(x, y)
    }
    return screens.indices.min { gap(screens[$0].frame) < gap(screens[$1].frame) }
  }

  // MARK: Arithmetic

  /// How far `value` is along a stretch, kept away from both ends by `cornerMargin`.
  private static func fraction(_ value: CGFloat, from start: CGFloat, length: CGFloat) -> Double {
    guard length > cornerMargin * 2 else { return 0.5 }
    let kept = min(max(value, start + cornerMargin), start + length - cornerMargin)
    return Double((kept - start) / length)
  }

  private static func place(_ along: Double, from start: CGFloat, length: CGFloat) -> CGFloat {
    guard length > cornerMargin * 2 else { return start + length / 2 }
    let value = start + CGFloat(along) * length
    return min(max(value, start + cornerMargin), start + length - cornerMargin)
  }

  /// Moves a stretch of `length` that starts at `value` into the room given. A stretch
  /// longer than the room is centred on it.
  private static func fit(_ value: CGFloat, length: CGFloat, into start: CGFloat, _ room: CGFloat) -> CGFloat
  {
    guard length <= room else { return start + (room - length) / 2 }
    return min(max(value, start), start + room - length)
  }
}

/// The spots the pill was dragged to, one for each arrangement of displays.
///
/// With a laptop alone the pill can be on the left; with a monitor plugged in, at the top
/// of the monitor. Each arrangement keeps its own spot, and an arrangement the pill was
/// never moved in has none (the pill is then at `PillSpot.home`).
public struct PillMemory: Codable, Equatable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    var spot: PillSpot
    /// The frame of the display the pill is on: x, y, width, height.
    var display: [Double]
  }

  var entries: [String: Entry] = [:]

  public init() {}

  /// Nothing is remembered.
  public var isEmpty: Bool { entries.isEmpty }

  /// The remembered spot for these displays: which display, and where on it.
  /// `nil` when there is none, or when it no longer fits (the display is gone or has another size).
  public func placement(among screens: [PillScreen]) -> (screen: Int, spot: PillSpot)? {
    guard let entry = entries[Self.arrangement(of: screens)] else { return nil }
    guard entry.spot.along.isFinite, (0...1).contains(entry.spot.along) else { return nil }
    guard let index = screens.firstIndex(where: { Self.numbers(of: $0.frame) == entry.display }) else {
      return nil
    }
    return (index, entry.spot)
  }

  /// Remembers `spot` on one of `screens` for this arrangement of displays.
  public mutating func remember(_ spot: PillSpot, onScreen index: Int, among screens: [PillScreen]) {
    guard screens.indices.contains(index) else { return }
    entries[Self.arrangement(of: screens)] = Entry(
      spot: spot,
      display: Self.numbers(of: screens[index].frame)
    )
  }

  /// A name for a set of displays: their frames, in a fixed order.
  static func arrangement(of screens: [PillScreen]) -> String {
    screens
      .map { numbers(of: $0.frame).map { String(Int($0)) }.joined(separator: ",") }
      .sorted()
      .joined(separator: "|")
  }

  private static func numbers(of frame: CGRect) -> [Double] {
    [frame.minX, frame.minY, frame.width, frame.height].map { Double($0.rounded()) }
  }
}

/// Where the user put the pill, kept between launches.
///
/// The pill's window reads the spot for the displays that are connected and writes a new
/// one after a drag. Settings and the pill's menu call `reset()`.
@MainActor
@Observable
public final class PillSpots {
  /// Every remembered spot. Changes when the pill is moved or put back.
  public private(set) var memory: PillMemory

  @ObservationIgnored private let defaults: UserDefaults?
  private static let key = "pill.spots"

  /// - defaults: where the spots are kept, or `nil` to keep nothing (demo, snapshots).
  public init(defaults: UserDefaults?) {
    self.defaults = defaults
    let saved = defaults?.data(forKey: Self.key)
    memory = saved.flatMap { try? JSONDecoder().decode(PillMemory.self, from: $0) } ?? PillMemory()
  }

  /// The pill was dragged somewhere, with any arrangement of displays.
  public var isMoved: Bool { !memory.isEmpty }

  /// Remembers where the pill was dropped.
  public func remember(_ spot: PillSpot, onScreen index: Int, among screens: [PillScreen]) {
    memory.remember(spot, onScreen: index, among: screens)
    save()
  }

  /// Puts the pill back at the middle of the bottom edge, for every arrangement of displays.
  public func reset() {
    guard isMoved else { return }
    memory = PillMemory()
    save()
  }

  private func save() {
    guard let defaults else { return }
    if memory.isEmpty {
      defaults.removeObject(forKey: Self.key)
    } else if let data = try? JSONEncoder().encode(memory) {
      defaults.set(data, forKey: Self.key)
    }
  }
}
