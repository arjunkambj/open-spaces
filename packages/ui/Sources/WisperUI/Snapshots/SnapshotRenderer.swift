#if os(macOS)
  import AppKit
  import SwiftUI
  import WisperEngine

  /// Renders snapshot cases to PNG files without showing anything on screen.
  ///
  /// Each case is hosted in a real (off-screen) window, so text fields, scroll views and
  /// menus draw as they do in the app. The view gets a loaded `AppModel` in the environment,
  /// the canvas size, the colour scheme, a background and a dialog host:
  ///
  /// - `.mac` stands for the hub's content area: panel background, Mac idiom.
  /// - `.phone` is an iPhone screen: panel background, phone idiom, safe areas for the
  ///   status bar and home indicator.
  /// - `.custom` is a bare canvas on the window background, Mac idiom.
  @MainActor
  public struct SnapshotRenderer {
    /// What went wrong while rendering.
    public enum Failure: Error, LocalizedError {
      case couldNotDraw(String)
      case couldNotEncode(String)

      public var errorDescription: String? {
        switch self {
        case .couldNotDraw(let name): "Could not draw the snapshot “\(name)”."
        case .couldNotEncode(let name): "Could not turn the snapshot “\(name)” into a PNG file."
        }
      }
    }

    /// Pixels per point in the files.
    private static let scale: CGFloat = 2
    /// How long to let layout and `.task`s finish before capturing.
    private static let settle: Duration = .milliseconds(350)

    public init() {}

    /// Writes `<name>-light.png` and `<name>-dark.png` for every case into `folder`
    /// (created when missing) and returns the files in the order written.
    /// - progress: called after each file is written.
    @discardableResult
    public func render(
      _ cases: [SnapshotCase],
      to folder: URL,
      progress: (URL) -> Void = { _ in }
    ) async throws -> [URL] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var written: [URL] = []
      for snapshot in cases {
        for scheme in [ColorScheme.light, .dark] {
          let suffix = scheme == .dark ? "dark" : "light"
          let file = folder.appendingPathComponent("\(snapshot.name)-\(suffix).png")
          try await png(of: snapshot, scheme: scheme).write(to: file, options: .atomic)
          written.append(file)
          progress(file)
        }
      }
      return written
    }

    /// The PNG data of one case in one colour scheme.
    private func png(of snapshot: SnapshotCase, scheme: ColorScheme) async throws -> Data {
      _ = NSApplication.shared
      let model = snapshot.model()
      await model.load()

      let size = snapshot.canvas.size
      let hosting = NSHostingView(rootView: SnapshotFrame(snapshot: snapshot, scheme: scheme, model: model))
      hosting.frame = CGRect(origin: .zero, size: size)

      // Far outside every display: the window exists and lays out, but is never seen.
      let window = NSWindow(
        contentRect: CGRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      window.hasShadow = false
      window.ignoresMouseEvents = true
      window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      window.contentView = hosting
      window.orderFrontRegardless()
      defer { window.close() }

      try? await Task.sleep(for: Self.settle)
      hosting.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      CATransaction.flush()

      guard let capture = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw Failure.couldNotDraw(snapshot.name)
      }
      hosting.cacheDisplay(in: hosting.bounds, to: capture)
      guard let image = capture.cgImage else { throw Failure.couldNotDraw(snapshot.name) }
      return try encode(image, size: size, name: snapshot.name)
    }

    /// Encodes at exactly `size * scale` pixels, whatever the density of the Mac's display.
    private func encode(_ image: CGImage, size: CGSize, name: String) throws -> Data {
      let width = Int((size.width * Self.scale).rounded())
      let height = Int((size.height * Self.scale).rounded())
      var output = image
      if image.width != width || image.height != height {
        guard
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
        else { throw Failure.couldNotEncode(name) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw Failure.couldNotEncode(name) }
        output = scaled
      }
      let rep = NSBitmapImageRep(cgImage: output)
      rep.size = size
      guard let data = rep.representation(using: .png, properties: [:]) else {
        throw Failure.couldNotEncode(name)
      }
      return data
    }
  }

  /// The case's view dressed the way the app would show it.
  private struct SnapshotFrame: View {
    let snapshot: SnapshotCase
    let scheme: ColorScheme
    let model: AppModel

    var body: some View {
      let size = snapshot.canvas.size
      content
        .frame(width: size.width, height: size.height)
        .background(background)
        .environment(model)
        .environment(\.wisperIdiom, snapshot.canvas == .phone ? .phone : .mac)
        .environment(\.colorScheme, scheme)
    }

    @ViewBuilder private var content: some View {
      if snapshot.canvas == .phone {
        snapshot.view
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .safeAreaInset(edge: .top, spacing: 0) { SwiftUI.Color.clear.frame(height: 59) }
          .safeAreaInset(edge: .bottom, spacing: 0) { SwiftUI.Color.clear.frame(height: 34) }
          .overlay(alignment: .top) {
            Capsule().fill(SwiftUI.Color.black).frame(width: 124, height: 36).padding(.top, 12)
          }
          .overlay(alignment: .bottom) {
            Capsule().fill(Wisper.Color.textPrimary).frame(width: 138, height: 5).padding(.bottom, 8)
          }
      } else {
        snapshot.view
      }
    }

    private var background: SwiftUI.Color {
      switch snapshot.canvas {
      case .mac, .phone: Wisper.Color.panel
      case .custom: Wisper.Color.window
      }
    }
  }
#endif
