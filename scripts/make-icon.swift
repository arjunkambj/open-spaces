// make-icon: draws the Open Wisper icon and writes every size it is needed in.
//
//   swift scripts/make-icon.swift
//
// The artwork is drawn here in code, so it is original and anyone can
// reproduce or change it. It writes:
//
//   assets/icon-1024.png                 the macOS icon (rounded square on a clear background)
//   assets/AppIcon.iconset/              the same at every size macOS asks for
//   apps/macos/Resources/AppIcon.icns    made from the iconset with `iconutil`
//   assets/icon-ios-1024.png             full square, no transparency (iOS adds the corners)
//   assets/menubar-template.pdf          one-colour mark for the menu bar (vector)
//   assets/menubar-template.png, @2x     the same as pixels, at 1x and 2x
//
// The mark is a sound wave that is also a lower-case "w", followed by a text
// cursor: what you say, written where you are typing. It is drawn on the
// app's pine green, in its paper white, with the cursor in its light green.
//
// The same mark is drawn in SwiftUI for the app itself, in
// packages/ui/Sources/WisperUI/Design/Wordmark.swift. Keep the two alike.
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

// The app's own colours (packages/ui, Colors.swift): the pine accent `1F6A4D` sits in the
// middle of the plate, the mark is the paper white `FAFAF9`, the cursor a shade of the light accent `79D2A8`.
let plateTop = color(0x29795A)
let plateBottom = color(0x124532)
let paper = color(0xFAFAF9)
let cursorGreen = color(0x8ADDB5)

// MARK: - The mark

/// The sizes of the mark, as shares of the width it is drawn for.
struct Mark {
  /// The thickness of the wave.
  var stroke: CGFloat
  /// How far the wave moves sideways from one turn to the next.
  var step: CGFloat
  /// How far it moves up or down between turns.
  var rise: CGFloat
  /// How round the turns of the wave are: the radius of the middle of the line.
  var corner: CGFloat
  /// The space between the wave and the cursor.
  var gap: CGFloat
  var cursorWidth: CGFloat
  var cursorHeight: CGFloat
  /// How far the wave sits below the middle of the cursor, the way a small letter does in a line of text.
  var drop: CGFloat

  var width: CGFloat { 4 * step + stroke + gap + cursorWidth }

  /// The mark on the icon. Small icons get a heavier mark with plain turns, so it survives at 16 pixels.
  static func icon(pixels: CGFloat) -> Mark {
    if pixels <= 16 {
      return Mark(
        stroke: 0.128,
        step: 0.125,
        rise: 0.3,
        corner: 0,
        gap: 0.09,
        cursorWidth: 0.143,
        cursorHeight: 0.643,
        drop: 0
      )
    }
    if pixels <= 32 {
      return Mark(
        stroke: 0.1,
        step: 0.112,
        rise: 0.29,
        corner: 0,
        gap: 0.08,
        cursorWidth: 0.094,
        cursorHeight: 0.54,
        drop: 0
      )
    }
    if pixels <= 64 {
      return Mark(
        stroke: 0.094,
        step: 0.112,
        rise: 0.29,
        corner: 0.034,
        gap: 0.082,
        cursorWidth: 0.09,
        cursorHeight: 0.5,
        drop: 0.012
      )
    }
    return Mark(
      stroke: 0.088,
      step: 0.114,
      rise: 0.3,
      corner: 0.058,
      gap: 0.084,
      cursorWidth: 0.078,
      cursorHeight: 0.5,
      drop: 0.017
    )
  }

  /// The mark in the menu bar, as shares of its height: lighter, like the system's own menu bar symbols.
  static let menuBar = Mark(
    stroke: 1.5 / 16,
    step: 3 / 16,
    rise: 7.5 / 16,
    corner: 0.9 / 16,
    gap: 2 / 16,
    cursorWidth: 1.5 / 16,
    cursorHeight: 13 / 16,
    drop: 0
  )
}

/// Draws the mark centred on `center`. `unit` is the length that the mark's shares are shares of.
/// With `snap` the mark sits on whole pixels, which keeps it sharp in small icons.
func drawMark(
  _ mark: Mark,
  in context: CGContext,
  center: CGPoint,
  unit: CGFloat,
  wave: CGColor,
  cursor: CGColor,
  snap: Bool = false
) {
  let stroke = mark.stroke * unit
  var left = center.x - mark.width * unit / 2 + stroke / 2
  if snap { left = (left - stroke / 2).rounded() + stroke / 2 }
  let top = center.y + (mark.rise / 2 - mark.drop) * unit
  let bottom = center.y - (mark.rise / 2 + mark.drop) * unit
  let step = mark.step * unit

  // Down, up, down, up: two dips. A wave, and a "w".
  let turns = [
    CGPoint(x: left, y: top), CGPoint(x: left + step, y: bottom), CGPoint(x: left + 2 * step, y: top),
    CGPoint(x: left + 3 * step, y: bottom), CGPoint(x: left + 4 * step, y: top),
  ]
  let path = CGMutablePath()
  path.move(to: turns[0])
  for index in 1..<(turns.count - 1) {
    path.addArc(tangent1End: turns[index], tangent2End: turns[index + 1], radius: mark.corner * unit)
  }
  path.addLine(to: turns[turns.count - 1])

  context.saveGState()
  context.addPath(path)
  context.setStrokeColor(wave)
  context.setLineWidth(stroke)
  context.setLineCap(.round)
  context.setLineJoin(.round)
  context.strokePath()

  var bar = CGRect(
    x: left + 4 * step + stroke / 2 + mark.gap * unit,
    y: center.y - mark.cursorHeight * unit / 2,
    width: mark.cursorWidth * unit,
    height: mark.cursorHeight * unit
  )
  if snap {
    bar = CGRect(
      x: bar.minX.rounded(),
      y: bar.minY.rounded(),
      width: max(1, bar.width.rounded()),
      height: bar.height.rounded()
    )
  }
  let radius = bar.width / 2
  context.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
  context.setFillColor(cursor)
  context.fillPath()
  context.restoreGState()
}

// MARK: - The plate

/// The pine green of the plate: lighter at the top, with a soft light from above.
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
    colors: [color(0xD9FFE9, alpha: 0.09), color(0xD9FFE9, alpha: 0)] as CFArray,
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
      top: color(0xE6FFF2, alpha: 0.34),
      bottom: color(0xE6FFF2, alpha: 0),
      stops: [0, 0.42]
    )
    drawInnerEdge(
      in: context,
      shape: shape,
      rect: plate,
      width: line,
      top: color(0x000000, alpha: 0),
      bottom: color(0x000000, alpha: 0.26),
      stops: [0.6, 1]
    )
  }

  drawMark(
    .icon(pixels: size),
    in: context,
    center: CGPoint(x: plate.midX, y: plate.midY),
    unit: plate.width,
    wave: paper,
    cursor: cursorGreen,
    snap: size <= 64
  )
}

/// The iOS icon: the same artwork filling the whole square, fully opaque. iOS rounds the corners.
func drawIOSIcon(in context: CGContext, size: CGFloat) {
  let square = CGRect(x: 0, y: 0, width: size, height: size)
  drawPlateColour(in: context, rect: square)
  // A little smaller than the plate would suggest: the Home Screen crops closer than the Dock does.
  drawMark(
    .icon(pixels: size),
    in: context,
    center: CGPoint(x: square.midX, y: square.midY),
    unit: size * 0.9,
    wave: paper,
    cursor: cursorGreen
  )
}

/// The menu bar mark: black on clear, 16 points tall. macOS tints it to suit the menu bar.
let menuBarHeight: CGFloat = 16
let menuBarWidth: CGFloat = 18

func drawMenuBarMark(in context: CGContext, scale: CGFloat) {
  let black = color(0x000000)
  drawMark(
    .menuBar,
    in: context,
    center: CGPoint(x: menuBarWidth * scale / 2, y: menuBarHeight * scale / 2),
    unit: menuBarHeight * scale,
    wave: black,
    cursor: black
  )
}

// MARK: - Files

func bitmap(
  width: Int,
  height: Int,
  opaque: Bool = false,
  draw: (CGContext) -> Void
) -> CGImage {
  let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
  let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: alpha.rawValue
  )!
  context.interpolationQuality = .high
  context.setShouldAntialias(true)
  draw(context)
  return context.makeImage()!
}

func square(pixels: Int, opaque: Bool = false, draw: (CGContext, CGFloat) -> Void) -> CGImage {
  bitmap(width: pixels, height: pixels, opaque: opaque) { draw($0, CGFloat(pixels)) }
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

  try writePNG(
    square(pixels: 1024, opaque: true, draw: drawIOSIcon),
    to: assets.appendingPathComponent("icon-ios-1024.png")
  )

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
