#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  import WisperEngine

  @testable import WisperUI

  /// Average brightness (0...255) of the pixel in the middle of a PNG.
  private func centreBrightness(_ png: Data) throws -> Double {
    let rep = try #require(NSBitmapImageRep(data: png))
    let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
    let rgb = try #require(color.usingColorSpace(.sRGB))
    return Double(rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3 * 255
  }

  private func pixelSize(_ png: Data) throws -> (width: Int, height: Int) {
    let rep = try #require(NSBitmapImageRep(data: png))
    return (rep.pixelsWide, rep.pixelsHigh)
  }

  /// Reads the model from the environment: white without an API key, black with one.
  private struct KeyProbe: View {
    @Environment(AppModel.self) private var model

    var body: some View {
      (model.isLoaded && model.hasAPIKey ? Color.black : Color.white)
    }
  }

  @MainActor
  @Suite(.serialized)
  struct SnapshotRendererTests {
    private let quick = SnapshotRenderer(settle: .milliseconds(60))

    @Test func writesLightAndDarkFilesAtTwoTimesTheCanvas() async throws {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("wisper-snapshots-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: folder) }

      let snapshot = SnapshotCase("probe", canvas: .custom(width: 120, height: 80)) {
        Wisper.Color.panel
      }
      var reported: [String] = []
      let files = try await quick.render([snapshot], to: folder) { reported.append($0.lastPathComponent) }

      #expect(files.map(\.lastPathComponent) == ["probe-light.png", "probe-dark.png"])
      #expect(reported == ["probe-light.png", "probe-dark.png"])
      for file in files {
        let data = try Data(contentsOf: file)
        #expect(data.count > 100)
        let size = try pixelSize(data)
        #expect(size.width == 240 && size.height == 160)
      }
      // The same token is light in one file and dark in the other.
      #expect(try centreBrightness(Data(contentsOf: files[0])) > 220)
      #expect(try centreBrightness(Data(contentsOf: files[1])) < 60)
    }

    @Test func honoursTheScale() async throws {
      let renderer = SnapshotRenderer(scale: 1, settle: .milliseconds(60))
      let snapshot = SnapshotCase("probe", canvas: .phone) { Text("Hello") }
      let size = try pixelSize(try await renderer.png(of: snapshot, scheme: .light))
      #expect(size.width == 393 && size.height == 852)
    }

    @Test func putsALoadedDemoModelInTheEnvironment() async throws {
      let standard = SnapshotCase("probe", canvas: .custom(width: 40, height: 40)) { KeyProbe() }
      #expect(try centreBrightness(try await quick.png(of: standard, scheme: .light)) < 40)

      let withoutKey = SnapshotCase(
        "probe",
        canvas: .custom(width: 40, height: 40),
        model: { .demo(hasAPIKey: false) }
      ) { KeyProbe() }
      #expect(try centreBrightness(try await quick.png(of: withoutKey, scheme: .light)) > 220)
    }

    @Test func drawsRealControls() async throws {
      // A plain ImageRenderer leaves text fields blank; a hosted window draws them.
      let snapshot = SnapshotCase("probe", canvas: .custom(width: 200, height: 60)) {
        WisperTextField(text: .constant("MMMMMMMMMMMMMMMMMMMMMMMMMM"), placeholder: "")
          .padding(8)
          .background(Color.white)
      }
      let rep = try #require(NSBitmapImageRep(data: try await quick.png(of: snapshot, scheme: .light)))
      var darkPixels = 0
      for x in stride(from: 40, to: rep.pixelsWide - 40, by: 2) {
        let color = rep.colorAt(x: x, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        if let color, color.redComponent < 0.5 { darkPixels += 1 }
      }
      #expect(darkPixels > 10, "the typed text is drawn")
    }

    @Test func everyGalleryCaseRendersOnMacAndPhone() async throws {
      let cases = DesignSnapshots.cases
      #expect(cases.contains { $0.canvas == .phone })
      #expect(cases.contains { $0.canvas == .mac })
      for snapshot in cases {
        for scheme in [ColorScheme.light, .dark] {
          let data = try await quick.png(of: snapshot, scheme: scheme)
          let size = try pixelSize(data)
          #expect(size.width == Int(snapshot.canvas.size.width * 2), "\(snapshot.name)")
          #expect(size.height == Int(snapshot.canvas.size.height * 2), "\(snapshot.name)")
        }
      }
    }

    @Test func registryNamesAreUniqueAndIncludeTheGallery() {
      let names = SnapshotRegistry.all.map(\.name)
      #expect(Set(names).count == names.count)
      #expect(names.contains("kit-controls"))
      #expect(names.contains("kit-phone-page"))
    }
  }
#endif
