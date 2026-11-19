import AVFoundation
import Foundation
import Testing
import WisperDomain

@testable import WisperAudio

/// Checks against real hardware. They are skipped unless asked for, because
/// they record real sound and the system-audio one can show a consent prompt.
///
///     WISPER_LIVE=microphone ../../scripts/swiftw test --filter Live
///     WISPER_LIVE=system ../../scripts/swiftw test --filter Live
///     WISPER_LIVE=microphone,system WISPER_LIVE_SECONDS=30 WISPER_LIVE_KEEP=1 \
///       ../../scripts/swiftw test --filter Live
///
/// `WISPER_LIVE_KEEP=1` leaves the files in a temporary folder and prints its
/// path, so they can be listened to.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct LiveTests {
  private static let wanted = Set(
    (ProcessInfo.processInfo.environment["WISPER_LIVE"] ?? "").split(separator: ",").map(String.init)
  )
  private static let seconds = Double(ProcessInfo.processInfo.environment["WISPER_LIVE_SECONDS"] ?? "") ?? 4
  private static let keep = ProcessInfo.processInfo.environment["WISPER_LIVE_KEEP"] != nil

  private func capture(
    _ tracks: Set<AudioTrack>,
    chunkSeconds: TimeInterval?,
    microphoneID: String? = nil
  ) async throws -> [AudioChunk] {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("wisper-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { if !LiveTests.keep { try? FileManager.default.removeItem(at: folder) } }

    let request = CaptureRequest(
      tracks: tracks,
      microphoneID: microphoneID,
      directory: folder,
      chunkSeconds: chunkSeconds
    )
    let session = try await SystemAudioCapture().start(request)
    let meter = Task { await session.levels.all() }
    let files = Task { await session.chunks.all() }
    try await Task.sleep(for: .seconds(LiveTests.seconds))
    await session.stop()

    let levels = await meter.value
    let chunks = await files.value
    print("live \(tracks.map(\.rawValue).sorted()): \(levels.count) levels, loudest \(levels.max() ?? 0)")
    for chunk in chunks {
      let decoded = try Decoded(chunk.url)
      let size = (try? FileManager.default.attributesOfItem(atPath: chunk.url.path)[.size] as? Int) ?? 0
      let loudness = decoded.loudness(from: 0, to: decoded.seconds)
      print(
        "  \(chunk.url.lastPathComponent) offset \(chunk.offset) duration \(chunk.duration)",
        "bytes \(size) loudness \(loudness)"
      )
      #expect(decoded.sampleRate == 16_000)
      #expect(decoded.channels == 1)
      #expect(abs(decoded.seconds - chunk.duration) < 0.2)
    }
    if LiveTests.keep { print("  files kept in \(folder.path)") }
    // About 20 meter values a second.
    #expect(Double(levels.count) > LiveTests.seconds * 15)
    return chunks
  }

  @Test(.enabled(if: wanted.contains("microphone")))
  func microphone() async throws {
    let chunks = try await capture([.microphone], chunkSeconds: nil)
    #expect(chunks.count == 1)
    let chunk = try #require(chunks.first)
    #expect(chunk.offset < 1.5)
    #expect(chunk.duration > LiveTests.seconds - 1.5)
  }

  @Test(.enabled(if: wanted.contains("microphone")))
  func microphoneChosenByID() async throws {
    let devices = await SystemAudioCapture().microphones()
    print("live microphones: \(devices.map { "\($0.name)\($0.isDefault ? " (default)" : "")" })")
    // Naming the default device must work, and so must a device that is gone.
    let preferred = try #require(devices.first(where: \.isDefault) ?? devices.first)
    for id in [preferred.id, "a-device-that-was-unplugged"] {
      let chunks = try await capture([.microphone], chunkSeconds: 1, microphoneID: id)
      #expect(chunks.count >= 2)
      // A room is never silent enough to leave holes: each file starts where the last ended.
      for (earlier, later) in zip(chunks, chunks.dropFirst()) {
        #expect(abs(later.offset - (earlier.offset + earlier.duration)) < 0.02)
      }
      // The list is still clean while the engine's own private device exists.
      let listed = await SystemAudioCapture().microphones()
      #expect(listed.map(\.id) == devices.map(\.id))
    }
  }

  #if os(macOS)
    @Test(.enabled(if: wanted.contains("system")))
    func system() async throws {
      // Play something (music, a video) while this runs, or no file comes out.
      let chunks = try await capture([.system], chunkSeconds: 2)
      #expect(chunks.allSatisfy { $0.track == .system })
      print("  \(chunks.count) system files; none is expected when nothing was playing")
    }

    @Test(.enabled(if: wanted.contains("microphone") && wanted.contains("system")))
    func both() async throws {
      let chunks = try await capture([.microphone, .system], chunkSeconds: 2)
      #expect(chunks.contains { $0.track == .microphone })
    }
  #endif
}
