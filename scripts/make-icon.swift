// make-icon: draws the Spaces icon and writes every size it is needed in.
//
//   swift scripts/make-icon.swift
//
// The artwork is drawn here in code, so it is original and anyone can
// reproduce or change it. It writes:
//
//   assets/icon-1024.png                 the macOS icon (rounded square on a clear background)
//   assets/AppIcon.iconset/              the same at every size macOS asks for
//   apps/macos/Resources/AppIcon.icns    made from the iconset with `iconutil`
//   assets/menubar-template.pdf          one-colour mark for the menu bar (vector)
//   assets/menubar-template.png, @2x     the same as pixels, at 1x and 2x
//
// The mark is the space bar, speaking: a solid capsule, twice as wide as it
// is tall, with three voice bars cut out of it, short, tall, short. It is
// drawn in white on a near-black plate. Black and white, like the app.
//
// The same mark is drawn in SwiftUI for the app itself, in
// packages/ui/Sources/SpacesUI/Design/Wordmark.swift. Keep the two alike.
//
// macOS 26 and later redraw an icon that comes as a plain `.icns`: they cut
// the mark out of the plate and put it on their own dark, clear or tinted
// plate when the person asks for that look. So the mark is kept light, flat
// and hard-edged, and the plate dark, which survives all of those.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Colours

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(
    colorSpace: colorSpace,
    components: [
      CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ]
  )!
}

// The app's own ink (packages/ui, Colors.swift): the plate runs from a soft black at the top
// to the app's near-black `0D0D0D`, and the mark is plain white.
let plateTop = color(0x2B2B2B)
let plateBottom = color(0x0D0D0D)
let paper = color(0xFFFFFF)

// MARK: - The mark

/// The sizes of the mark, as shares of its height.
struct Mark {
  /// How wide the capsule is.
  var width: CGFloat = 2
  /// The thickness of a bar.
  var bar: CGFloat
  /// From the middle of one bar to the middle of the next.
  var step: CGFloat
  /// The length of the two outer bars, and of the middle one.
  var short: CGFloat
  var tall: CGFloat

  /// The mark on the icon. Small icons get heavier bars, so they survive at 16 pixels.
  static func icon(pixels: CGFloat) -> Mark {
    if pixels <= 32 {
      return Mark(bar: 0.22, step: 0.38, short: 0.34, tall: 0.62)
    }
    return Mark(bar: 0.16, step: 0.3, short: 0.3, tall: 0.58)
  }

  /// The mark in the menu bar: the same, with bars a little heavier for its small size.
  static let menuBar = Mark(bar: 0.2, step: 0.34, short: 0.3, tall: 0.6)
}

/// Draws the mark centred on `center`, `height` tall, in `ink`. The bars are cut out of it,
/// so whatever is behind shows through. With `snap` the bars sit on whole pixels, which
/// keeps them sharp in small icons.
func drawMark(
  _ mark: Mark,
  in context: CGContext,
  center: CGPoint,
  height: CGFloat,
  ink: CGColor,
  snap: Bool = false
) {
  let capsule = CGRect(
    x: center.x - mark.width * height / 2,
    y: center.y - height / 2,
    width: mark.width * height,
    height: height
  )
  let path = CGMutablePath()
  path.addRoundedRect(in: capsule, cornerWidth: height / 2, cornerHeight: height / 2)
  for (offset, length) in [(-1, mark.short), (0, mark.tall), (1, mark.short)] {
    var bar = CGRect(
      x: center.x + CGFloat(offset) * mark.step * height - mark.bar * height / 2,
      y: center.y - length * height / 2,
      width: mark.bar * height,
      height: length * height
    )
    if snap {
      bar = CGRect(
        x: bar.minX.rounded(),
        y: bar.minY.rounded(),
        width: max(1, bar.width.rounded()),
        height: bar.height.rounded()
      )
    }
    path.addRoundedRect(in: bar, cornerWidth: bar.width / 2, cornerHeight: bar.width / 2)
  }
  context.saveGState()
  context.addPath(path)
  context.setFillColor(ink)
  context.fillPath(using: .evenOdd)
  context.restoreGState()
}

// MARK: - The plate

/// The near-black of the plate: a little lighter at the top, with a soft light from above.
func drawPlateColour(in context: CGContext, rect: CGRect) {
  let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [plateTop, plateBottom] as CFArray,
    locations: [0, 1]
  )!
  context.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.minY),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
  )
  let light = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0xFFFFFF, alpha: 0.06), color(0xFFFFFF, alpha: 0)] as CFArray,
    locations: [0, 1]
  )!
  let source = CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.08)
  context.drawRadialGradient(
    light,
    startCenter: source,
    startRadius: 0,
    endCenter: source,
    endRadius: rect.width * 0.82,
    options: []
  )
}

/// The rounded square macOS icons use: its corners ease in, they are not plain quarter circles.
func plateShape(_ rect: CGRect) -> CGPath {
  RoundedRectangle(cornerRadius: rect.width * 0.2237, style: .continuous).path(in: rect).cgPath
}

/// A thin line just inside the edge of `shape`, fading from `top` to `bottom` between `stops`.
func drawInnerEdge(
  in context: CGContext,
  shape: CGPath,
  rect: CGRect,
  width: CGFloat,
  top: CGColor,
  bottom: CGColor,
  stops: [CGFloat]
) {
  context.saveGState()
  context.addPath(shape)
  context.clip()
  context.addPath(shape)
  context.setLineWidth(width * 2)
  context.replacePathWithStrokedPath()
  context.clip()
  let gradient = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray, locations: stops)!
  context.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.minY),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
  )
  context.restoreGState()
}

/// The height of the mark on the plate, as a share of the plate's width.
let markOnPlate: CGFloat = 0.31

/// The macOS icon: the plate with the system's usual room around it and a soft shadow.
func drawMacIcon(in context: CGContext, size: CGFloat) {
  // 100 of 1024 on each side, as Apple's icon grid has it. Small icons sit on whole pixels and
  // keep a little less room, so their mark has pixels to live in.
  let room: CGFloat = size <= 16 ? 1 : (size * 100 / 1024).rounded(.down)
  let plate = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: room, dy: room)
  let shape = plateShape(plate)

  context.saveGState()
  context.setShadow(
    offset: CGSize(width: 0, height: -size * 10 / 1024),
    blur: size * 24 / 1024,
    color: color(0x000000, alpha: 0.3)
  )
  context.addPath(shape)
  context.setFillColor(plateBottom)
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(shape)
  context.clip()
  drawPlateColour(in: context, rect: plate)
  context.restoreGState()

  if size >= 64 {
    // A lit top edge and a shaded bottom edge: just enough to make the plate an object.
    let line = max(1, size * 3 / 1024)
    drawInnerEdge(
      in: context,
      shape: shape,
      rect: plate,
      width: line,
      top: color(0xFFFFFF, alpha: 0.22),
      bottom: color(0xFFFFFF, alpha: 0),
      stops: [0, 0.42]
    )
    drawInnerEdge(
      in: context,
      shape: shape,
      rect: plate,
      width: line,
      top: color(0x000000, alpha: 0),
      bottom: color(0x000000, alpha: 0.3),
      stops: [0.6, 1]
    )
  }

  // Small icons get a larger mark, so it still reads.
  let share: CGFloat = size <= 32 ? 0.36 : markOnPlate
  var height = plate.width * share
  if size <= 64 { height = height.rounded() }
  drawMark(
    .icon(pixels: size),
    in: context,
    center: CGPoint(x: plate.midX, y: plate.midY),
    height: height,
    ink: paper,
    snap: size <= 64
  )
}

/// The menu bar mark: black on clear, 16 points tall. macOS tints it to suit the menu bar.
let menuBarHeight: CGFloat = 16
let menuBarWidth: CGFloat = 22

func drawMenuBarMark(in context: CGContext, scale: CGFloat) {
  drawMark(
    .menuBar,
    in: context,
    center: CGPoint(x: menuBarWidth * scale / 2, y: menuBarHeight * scale / 2),
    height: 10 * scale,
    ink: color(0x000000)
  )
}

// MARK: - Files

func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
  let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.interpolationQuality = .high
  context.setShouldAntialias(true)
  draw(context)
  return context.makeImage()!
}

func square(pixels: Int, draw: (CGContext, CGFloat) -> Void) -> CGImage {
  bitmap(width: pixels, height: pixels) { draw($0, CGFloat(pixels)) }
}

func writePNG(_ image: CGImage, to url: URL) throws {
  guard
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw CocoaError(.fileWriteUnknown) }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

func writePDF(width: CGFloat, height: CGFloat, to url: URL, draw: (CGContext) -> Void) throws {
  var box = CGRect(x: 0, y: 0, width: width, height: height)
  guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
    throw CocoaError(.fileWriteUnknown)
  }
  context.beginPDFPage(nil)
  draw(context)
  context.endPDFPage()
  context.closePDF()
}

func run(_ tool: String, _ arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: tool)
  process.arguments = arguments
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw NSError(
      domain: "make-icon",
      code: Int(process.terminationStatus),
      userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"]
    )
  }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("assets", isDirectory: true)
let iconset = assets.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icns = root.appendingPathComponent("apps/macos/Resources/AppIcon.icns")
let files = FileManager.default

do {
  try? files.removeItem(at: iconset)
  try files.createDirectory(at: iconset, withIntermediateDirectories: true)
  try files.createDirectory(at: icns.deletingLastPathComponent(), withIntermediateDirectories: true)

  try writePNG(square(pixels: 1024, draw: drawMacIcon), to: assets.appendingPathComponent("icon-1024.png"))
  for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
      let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
      try writePNG(
        square(pixels: points * scale, draw: drawMacIcon),
        to: iconset.appendingPathComponent(name)
      )
    }
  }
  try? files.removeItem(at: icns)
  try run("/usr/bin/iconutil", ["--convert", "icns", iconset.path, "--output", icns.path])

  try writePDF(
    width: menuBarWidth,
    height: menuBarHeight,
    to: assets.appendingPathComponent("menubar-template.pdf")
  ) { drawMenuBarMark(in: $0, scale: 1) }
  for scale in [1, 2] {
    let name = scale == 1 ? "menubar-template.png" : "menubar-template@2x.png"
    try writePNG(
      bitmap(width: Int(menuBarWidth) * scale, height: Int(menuBarHeight) * scale) {
        drawMenuBarMark(in: $0, scale: CGFloat(scale))
      },
      to: assets.appendingPathComponent(name)
    )
  }
  print("Wrote the icon to \(assets.path) and \(icns.path)")
} catch {
  FileHandle.standardError.write(Data("make-icon failed: \(error.localizedDescription)\n".utf8))
  exit(1)
}
