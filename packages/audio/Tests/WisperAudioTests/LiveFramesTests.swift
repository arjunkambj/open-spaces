import Foundation
import Testing
import WisperDomain

@testable import WisperAudio

/// The sound a capture hands over while it records, next to the file it writes.
@Suite(.timeLimit(.minutes(1)))
struct LiveFramesTests {
  private func record(
    liveFrames: Bool,
    chunkSeconds: TimeInterval? = nil,
    in scratch: Scratch
  ) throws -> (Recording, ScriptedSource) {
    let source = ScriptedSource()
    let request = CaptureRequest(
      tracks: [.microphone],
      directory: scratch.url,
      chunkSeconds: chunkSeconds,
      liveFrames: liveFrames
    )
    return (try Recording.start(request, sources: [.microphone: source], origin: 0), source)
  }

  private func collect(_ frames: AsyncStream<AudioFrames>) async -> [AudioFrames] {
    var all: [AudioFrames] = []
    for await frame in frames { all.append(frame) }
    return all
  }

  @Test func theLiveSoundIsTheSoundInTheFile() async throws {
    let scratch = try Scratch()
    let (recording, source) = try record(liveFrames: true, in: scratch)
    // A device's own rate: what is handed over is already at the file's 16 kHz.
    source.play(Sound.tone(3), at: 0)
    await recording.stop()

    let frames = await collect(recording.frames)
    let chunk = try #require(await recording.chunks.all().first)

    #expect(frames.allSatisfy { $0.sampleRate == 16_000 })
    let samples = frames.flatMap(\.samples)
    // As long as the file, to within a hundredth of a second.
    #expect(abs(Double(samples.count) / 16_000 - chunk.duration) < 0.01)
    // And the same sound: RMS of a 0.1 sine is about 0.07.
    let middle = samples[8_000..<40_000]
    let rms = (middle.reduce(Float(0)) { $0 + $1 * $1 } / Float(middle.count)).squareRoot()
    #expect(abs(rms - 0.0707) < 0.01)
    // It came a little at a time, not in one lump at the end.
    #expect(frames.count > 10)
    #expect(frames.allSatisfy { $0.samples.count <= 16_000 })
  }

  @Test func theLiveSoundArrivesWhileTheRecordingIsStillRunning() async throws {
    let scratch = try Scratch()
    let (recording, source) = try record(liveFrames: true, in: scratch)
    source.play(Sound.tone(1), at: 0)

    var heard = 0
    for await frame in recording.frames {
      heard += frame.samples.count
      // Most of the first second has been handed over, and nobody has called `stop` yet.
      if heard >= 12_000 { break }
    }
    #expect(heard >= 12_000)
    await recording.cancel()
  }

  @Test func nothingIsHandedOverUnlessItWasAskedFor() async throws {
    let scratch = try Scratch()
    let (recording, source) = try record(liveFrames: false, in: scratch)
    source.play(Sound.tone(1), at: 0)
    await recording.stop()

    #expect(await collect(recording.frames).isEmpty)
    #expect(await recording.chunks.all().count == 1)
  }

  @Test func aRecordingCutIntoFilesHandsNothingOver() async throws {
    // Files of a meeting leave silence out, so "the sound in the file" would not hold.
    let scratch = try Scratch()
    let (recording, source) = try record(liveFrames: true, chunkSeconds: 5, in: scratch)
    source.play(Sound.tone(2), at: 0)
    await recording.stop()

    #expect(await collect(recording.frames).isEmpty)
  }

  @Test func cancellingEndsTheLiveSound() async throws {
    let scratch = try Scratch()
    let (recording, source) = try record(liveFrames: true, in: scratch)
    source.play(Sound.tone(1), at: 0)
    await recording.cancel()

    // Ends, instead of leaving its reader waiting for ever.
    _ = await collect(recording.frames)
    #expect(scratch.files.isEmpty)
  }

  @Test func aReaderThatNeverReadsCannotUseUpTheMemory() async throws {
    let scratch = try Scratch()
    let (recording, source) = try record(liveFrames: true, in: scratch)
    // Ten minutes, in buffers of 50 ms: 12,000 runs of sound, and nobody reading.
    source.play(Sound.silence(600, rate: 16_000), rate: 16_000, at: 0)
    await recording.stop()

    let frames = await collect(recording.frames)
    let chunk = try #require(await recording.chunks.all().first)

    #expect(frames.count <= Recording.mostFramesWaiting)
    // The file is whole all the same, and the count of samples gives the gap away.
    #expect(abs(chunk.duration - 600) < 0.05)
    #expect(Double(frames.reduce(0) { $0 + $1.samples.count }) / 16_000 < chunk.duration - 60)
  }
}
