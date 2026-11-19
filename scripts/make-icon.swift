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
//   assets/menubar-template.png, @2x     the same as pixels, 18 and 36 px
//
// The mark is a soft wave that is also a lower-case "w": a voice, and the
// first letter of the name.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Artwork

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(
    colorSpace: colorSpace,
    components: [
      CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ]
  )!
}

let backgroundTop = color(0xFFE3B3)
let backgroundBottom = color(0xFFA877)
let ink = color(0x3A1E14)

/// The wave, as a path inside `rect`. Two dips with a lower middle peak, so
/// it reads as a "w"; the stroke is drawn by the caller.
func wavePath(in rect: CGRect) -> CGPath {
  let path = CGMutablePath()
  let steps = 240
  for step in 0...steps {
    let t = CGFloat(step) / CGFloat(steps)
    // Two full waves from crest to crest. The middle crest is lower.
    let crest = cos(t * 4 * .pi)
    let dipToMiddle = 1 - 0.42 * pow(sin(t * .pi), 6)
    let y = crest > 0 ? crest * dipToMiddle : crest
    let point = CGPoint(x: rect.minX + t * rect.width, y: rect.midY + y * rect.height / 2)
    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
  }
  return path
}

func drawWave(in context: CGContext, rect: CGRect, lineWidth: CGFloat, color: CGColor) {
  context.saveGState()
  context.addPath(wavePath(in: rect))
  context.setStrokeColor(color)
  context.setLineWidth(lineWidth)
  context.setLineCap(.round)
  context.setLineJoin(.round)
  context.strokePath()
  context.restoreGState()
}

func drawBackground(in context: CGContext, rect: CGRect) {
  let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [backgroundTop, backgroundBottom] as CFArray,
    locations: [0, 1]
  )!
  context.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.minY),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
  )
  // A soft glow in the upper left, so the plate is not flat.
  let glow = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0xFFFFFF, alpha: 0.38), color(0xFFFFFF, alpha: 0)] as CFArray,
    locations: [0, 1]
  )!
  context.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.86),
    startRadius: 0,
    endCenter: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.86),
    endRadius: rect.width * 0.75,
    options: []
  )
}

/// The mark, sized for a plate that fills `plate`. Small sizes get a
/// heavier line so the wave survives at 16 pixels.
func drawMark(in context: CGContext, plate: CGRect, pixels: CGFloat) {
  let weight: CGFloat = pixels <= 32 ? 0.145 : (pixels <= 64 ? 0.122 : 0.102)
  let width = plate.width * 0.56
  let height = plate.height * (pixels <= 32 ? 0.27 : 0.29)
  let rect = CGRect(x: plate.midX - width / 2, y: plate.midY - height / 2, width: width, height: height)
  drawWave(in: context, rect: rect, lineWidth: plate.width * weight, color: ink)
}

/// The macOS icon: a rounded square with a little room around it and a soft shadow.
func drawMacIcon(in context: CGContext, size: CGFloat) {
  let plate = CGRect(x: 0, y: 0, width: size, height: size).insetBy(
    dx: size * 100 / 1024,
    dy: size * 100 / 1024
  )
  let shape = CGPath(
    roundedRect: plate,
    cornerWidth: plate.width * 0.2237,
    cornerHeight: plate.width * 0.2237,
    transform: nil
  )
  context.saveGState()
  context.setShadow(
    offset: CGSize(width: 0, height: -size * 10 / 1024),
    blur: size * 22 / 1024,
    color: color(0x000000, alpha: 0.28)
  )
  context.addPath(shape)
  context.setFillColor(backgroundBottom)
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(shape)
  context.clip()
  drawBackground(in: context, rect: plate)
  drawMark(in: context, plate: plate, pixels: size)
  context.restoreGState()

  // A hairline that keeps the edge crisp on light backgrounds.
  if size >= 128 {
    context.addPath(shape)
    context.setStrokeColor(color(0x7A3A1E, alpha: 0.16))
    context.setLineWidth(max(1, size / 512))
    context.strokePath()
  }
}

/// The iOS icon: the same artwork filling the whole square, fully opaque.
func drawIOSIcon(in context: CGContext, size: CGFloat) {
  let square = CGRect(x: 0, y: 0, width: size, height: size)
  drawBackground(in: context, rect: square)
  drawMark(in: context, plate: square.insetBy(dx: size * 0.04, dy: size * 0.04), pixels: size)
}

/// The menu bar mark: black on clear. macOS tints it to suit the menu bar.
func drawMenuBarMark(in context: CGContext, size: CGFloat) {
  let rect = CGRect(x: size * 0.14, y: size * 0.31, width: size * 0.72, height: size * 0.38)
  drawWave(in: context, rect: rect, lineWidth: size * 0.118, color: color(0x000000))
}

// MARK: - Files

func bitmap(pixels: Int, opaque: Bool = false, draw: (CGContext, CGFloat) -> Void) -> CGImage {
  let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
  let context = CGContext(
    data: nil,
    width: pixels,
    height: pixels,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: alpha.rawValue
  )!
  context.interpolationQuality = .high
  context.setShouldAntialias(true)
  draw(context, CGFloat(pixels))
  return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
  guard
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw CocoaError(.fileWriteUnknown) }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

func writePDF(points: CGFloat, to url: URL, draw: (CGContext, CGFloat) -> Void) throws {
  var box = CGRect(x: 0, y: 0, width: points, height: points)
  guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
    throw CocoaError(.fileWriteUnknown)
  }
  context.beginPDFPage(nil)
  draw(context, points)
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

  try writePNG(bitmap(pixels: 1024, draw: drawMacIcon), to: assets.appendingPathComponent("icon-1024.png"))
  for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
      let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
      try writePNG(
        bitmap(pixels: points * scale, draw: drawMacIcon),
        to: iconset.appendingPathComponent(name)
      )
    }
  }
  try run("/usr/bin/iconutil", ["--convert", "icns", iconset.path, "--output", icns.path])

  try writePNG(
    bitmap(pixels: 1024, opaque: true, draw: drawIOSIcon),
    to: assets.appendingPathComponent("icon-ios-1024.png")
  )

  try writePDF(points: 18, to: assets.appendingPathComponent("menubar-template.pdf"), draw: drawMenuBarMark)
  try writePNG(
    bitmap(pixels: 18, draw: drawMenuBarMark),
    to: assets.appendingPathComponent("menubar-template.png")
  )
  try writePNG(
    bitmap(pixels: 36, draw: drawMenuBarMark),
    to: assets.appendingPathComponent("menubar-template@2x.png")
  )
  print("Wrote the icon to \(assets.path) and \(icns.path)")
} catch {
  FileHandle.standardError.write(Data("make-icon failed: \(error.localizedDescription)\n".utf8))
  exit(1)
}
