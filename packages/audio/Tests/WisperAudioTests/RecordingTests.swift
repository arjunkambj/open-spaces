import Foundation
import Testing
import WisperDomain

@testable import WisperAudio

/// The whole path from raw samples to finished files, driven through the
/// `CaptureSession` interface with a scripted source in place of hardware.
@Suite(.timeLimit(.minutes(1)))
struct RecordingTests {
  private func record(
    _ tracks: Set<AudioTrack> = [.microphone],
    chunkSeconds: TimeInterval? = nil,
    in scratch: Scratch
  ) throws -> (Recording, [AudioTrack: ScriptedSource]) {
    var sources: [AudioTrack: ScriptedSource] = [:]
    for track in tracks { sources[track] = ScriptedSource() }
    let request = CaptureRequest(tracks: tracks, directory: scratch.url, chunkSeconds: chunkSeconds)
    let recording = try Recording.start(request, sources: sources, origin: 0)
    return (recording, sources)
  }

  @Test func oneFileIsSmallSpeechSizedAAC() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(in: scratch)
    sources[.microphone]?.play(Sound.tone(3), at: 0)
    await recording.stop()

    let chunks = await recording.chunks.all()
    #expect(chunks.count == 1)
    let chunk = try #require(chunks.first)
    #expect(chunk.track == .microphone)
    #expect(chunk.url.lastPathComponent == "microphone-0000.m4a")
    #expect(chunk.offset == 0)
    #expect(abs(chunk.duration - 3) < 0.02)

    let decoded = try Decoded(chunk.url)
    #expect(decoded.sampleRate == 16_000)
    #expect(decoded.channels == 1)
    #expect(abs(decoded.seconds - chunk.duration) < 0.15)
    // The tone survived the trip: RMS of a 0.1 sine is about 0.07.
    #expect(abs(decoded.loudness(from: 0.5, to: 2.5) - 0.0707) < 0.01)
    // About 32 kbps: 3 seconds is roughly 12 KB of sound plus a small header,
    // against 96 KB for the same sound uncompressed.
    let size = try #require(try FileManager.default.attributesOfItem(atPath: chunk.url.path)[.size] as? Int)
    #expect(size > 6_000 && size < 20_000)
  }

  @Test func aLongRecordingStaysOneFileWithoutChunking() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(in: scratch)
    // Longer than the minute of header space set aside up front.
    sources[.microphone]?.play(Sound.tone(150, rate: 16_000), rate: 16_000, at: 0)
    await recording.stop()
    let chunks = await recording.chunks.all()
    #expect(chunks.count == 1)
    let chunk = try #require(chunks.first)
    #expect(abs(chunk.duration - 150) < 0.02)
    let decoded = try Decoded(chunk.url)
    #expect(abs(decoded.seconds - 150) < 0.15)
    #expect(abs(decoded.loudness(from: 140, to: 149) - 0.0707) < 0.01)
  }

  @Test func steadySoundIsCutHardJustPastTheTarget() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(chunkSeconds: 2, in: scratch)
    sources[.microphone]?.play(Sound.tone(7), at: 0)

    // The first two files arrive while recording is still going.
    var stream = recording.chunks.makeAsyncIterator()
    let first = try #require(await stream.next())
    let second = try #require(await stream.next())
    #expect(first.url.lastPathComponent == "microphone-0000.m4a")
    #expect(second.url.lastPathComponent == "microphone-0001.m4a")
    // No pause ever comes, so each cut lands at the target plus 20%.
    #expect(abs(first.duration - 2.4) < 0.011)
    #expect(abs(second.duration - 2.4) < 0.011)
    #expect(try Decoded(first.url).sampleRate == 16_000)

    await recording.stop()
    let last = try #require(await stream.next())
    #expect(await stream.next() == nil)

    // The files follow each other with nothing lost and nothing repeated.
    #expect(first.offset == 0)
    #expect(abs(second.offset - (first.offset + first.duration)) < 0.001)
    #expect(abs(last.offset - (second.offset + second.duration)) < 0.001)
    #expect(abs(first.duration + second.duration + last.duration - 7) < 0.02)
  }

  @Test func cutsAtAPauseNearTheTarget() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(chunkSeconds: 2, in: scratch)
    let source = try #require(sources[.microphone])
    // Speech until 1.7 s, a half-second pause (room hiss), then speech again.
    var time = source.play(Sound.tone(1.7), at: 0)
    time = source.play(Sound.hiss(0.5), at: time)
    source.play(Sound.tone(2), at: time)
    await recording.stop()

    let chunks = await recording.chunks.all()
    #expect(chunks.count == 2)
    let first = try #require(chunks.first)
    // The cut falls inside the pause (1.7...2.2), not at the 2.4 s hard limit.
    #expect(first.duration > 1.9 && first.duration < 2.1)
    // Both sides of the cut are quiet: no word was split.
    let before = try Decoded(first.url)
    #expect(before.loudness(from: first.duration - 0.15, to: first.duration - 0.05) < 0.01)
    let after = try Decoded(try #require(chunks.last).url)
    #expect(after.loudness(from: 0.05, to: 0.1) < 0.01)
  }

  @Test func aPauseBeforeTheWindowDoesNotCutEarly() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(chunkSeconds: 4, in: scratch)
    let source = try #require(sources[.microphone])
    var time = source.play(Sound.tone(1), at: 0)
    time = source.play(Sound.hiss(0.5), at: time)
    source.play(Sound.tone(3), at: time)
    await recording.stop()
    let chunks = await recording.chunks.all()
    // 4.5 s of sound with a pause at 1 s: one file, because 1 s is too early to cut.
    #expect(chunks.count == 1)
  }

  @Test func bothTracksShareOneClock() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record([.microphone, .system], in: scratch)
    sources[.microphone]?.play(Sound.tone(2), at: 0.25)
    sources[.system]?.play(Sound.tone(1, rate: 44_100), rate: 44_100, at: 1)
    await recording.stop()

    let chunks = await recording.chunks.all()
    #expect(Set(chunks.map(\.track)) == [.microphone, .system])
    let microphone = try #require(chunks.first { $0.track == .microphone })
    let system = try #require(chunks.first { $0.track == .system })
    #expect(abs(microphone.offset - 0.25) < 0.001)
    #expect(abs(system.offset - 1) < 0.001)
    #expect(system.url.lastPathComponent == "system-0000.m4a")
    #expect(abs(system.duration - 1) < 0.02)
  }

  @Test func aShortDropoutIsFilledSoTheTimelineHolds() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(chunkSeconds: 30, in: scratch)
    let source = try #require(sources[.microphone])
    source.play(Sound.tone(1), at: 0)
    // Half a second goes missing (a device change), then sound returns.
    source.play(Sound.tone(1), at: 1.5)
    await recording.stop()

    let chunks = await recording.chunks.all()
    #expect(chunks.count == 1)
    let chunk = try #require(chunks.first)
    #expect(abs(chunk.duration - 2.5) < 0.03)
    let decoded = try Decoded(chunk.url)
    #expect(decoded.loudness(from: 1.15, to: 1.35) < 0.005)
    #expect(decoded.loudness(from: 1.7, to: 2.3) > 0.05)
  }

  @Test func aLongDropoutStartsANewFileAtTheRightOffset() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(chunkSeconds: 30, in: scratch)
    let source = try #require(sources[.microphone])
    source.play(Sound.tone(1), at: 0)
    // A phone call takes the microphone for a minute.
    source.play(Sound.tone(1), at: 61)
    await recording.stop()

    let chunks = await recording.chunks.all()
    #expect(chunks.count == 2)
    #expect(abs((chunks.first?.duration ?? 0) - 1) < 0.03)
    #expect(abs((chunks.last?.offset ?? 0) - 61) < 0.03)
    #expect(abs((chunks.last?.duration ?? 0) - 1) < 0.03)
  }

  @Test func aLongDropoutIsLeftOutOfASingleFile() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(in: scratch)
    let source = try #require(sources[.microphone])
    source.play(Sound.tone(1), at: 0)
    source.play(Sound.tone(1), at: 61)
    await recording.stop()

    let chunks = await recording.chunks.all()
    #expect(chunks.count == 1)
    #expect(abs((chunks.first?.duration ?? 0) - 2) < 0.03)
  }

  @Test func aSlowDeviceClockMovesOffsetsButAddsNoSilence() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(chunkSeconds: 10, in: scratch)
    let source = try #require(sources[.microphone])
    // A device that runs 0.5% slow: each 50 ms buffer takes 50.25 ms to arrive.
    let buffer = Sound.tone(0.05)
    for index in 0..<1_200 { source.play(buffer, at: Double(index) * 0.050_25) }
    await recording.stop()

    let chunks = await recording.chunks.all()
    #expect(chunks.count == 5)
    // All 60 seconds of samples are there, and not a sample more.
    #expect(abs(chunks.reduce(0) { $0 + $1.duration } - 60) < 0.02)
    // Later files start where the shared clock says, not where the count says:
    // the last one begins after 48 s of samples, which took 48.24 s to arrive.
    let last = try #require(chunks.last)
    #expect(abs(last.offset - 48.24) < 0.03)
    // Nothing was patched with silence along the way.
    let decoded = try Decoded(try #require(chunks.dropFirst(2).first).url)
    #expect(decoded.loudness(from: 0, to: decoded.seconds) > 0.06)
  }

  @Test func aChangeOfSampleRateCarriesOnInTheSameFile() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(in: scratch)
    let source = try #require(sources[.microphone])
    // Built-in microphone at 48 kHz, then a headset at 16 kHz and 24 kHz.
    var time = source.play(Sound.tone(1), at: 0)
    time = source.play(Sound.tone(1, rate: 16_000), rate: 16_000, at: time)
    source.play(Sound.tone(1, rate: 24_000), rate: 24_000, at: time)
    await recording.stop()

    let chunk = try #require(await recording.chunks.all().first)
    #expect(abs(chunk.duration - 3) < 0.03)
    let decoded = try Decoded(chunk.url)
    for second in [0.5, 1.5, 2.5] {
      #expect(abs(decoded.loudness(from: second - 0.2, to: second + 0.2) - 0.0707) < 0.01)
    }
  }

  @Test func aSilentTrackProducesNoFilesWhenChunking() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record([.system], chunkSeconds: 2, in: scratch)
    sources[.system]?.play(Sound.silence(7), at: 0)
    await recording.stop()
    #expect(await recording.chunks.all().isEmpty)
    #expect(scratch.files.isEmpty)
  }

  @Test func silenceBeforeTheFirstSoundIsLeftOutAndTheOffsetSaysSo() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record([.system], chunkSeconds: 30, in: scratch)
    let source = try #require(sources[.system])
    let time = source.play(Sound.silence(5), at: 0)
    source.play(Sound.tone(1), at: time)
    await recording.stop()

    let chunk = try #require(await recording.chunks.all().first)
    #expect(abs(chunk.offset - 5) < 0.06)
    #expect(abs(chunk.duration - 1) < 0.06)
  }

  @Test func oneFileIsPromisedEvenForSilence() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(in: scratch)
    sources[.microphone]?.play(Sound.silence(1), at: 0)
    await recording.stop()
    let chunk = try #require(await recording.chunks.all().first)
    #expect(abs(chunk.duration - 1) < 0.02)
    #expect(try Decoded(chunk.url).sampleRate == 16_000)
  }

  @Test func stoppingAtOnceStillGivesAReadableFile() async throws {
    let scratch = try Scratch()
    let (recording, _) = try record(in: scratch)
    await recording.stop()
    let chunks = await recording.chunks.all()
    #expect(chunks.count == 1)
    let chunk = try #require(chunks.first)
    // Padded to the shortest length the transcription API accepts.
    #expect(chunk.duration == 0.1)
    #expect(try Decoded(chunk.url).channels == 1)
  }

  @Test func stopFlushesBeforeItReturnsAndEndsBothStreams() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(chunkSeconds: 2, in: scratch)
    let source = try #require(sources[.microphone])
    source.play(Sound.tone(3), at: 0)
    await recording.stop()

    // Every file is on disk and complete the moment `stop` returns.
    #expect(scratch.files == ["microphone-0000.m4a", "microphone-0001.m4a"])
    for name in scratch.files {
      #expect(try Decoded(scratch.url.appendingPathComponent(name)).seconds > 0.5)
    }
    #expect(source.stopCount == 1)
    #expect(await recording.chunks.all().count == 2)
    #expect(await recording.levels.all().count > 0)

    // Sound that arrives late is ignored; stopping or cancelling again is harmless.
    source.play(Sound.tone(1), at: 3)
    await recording.stop()
    await recording.cancel()
    #expect(source.stopCount == 1)
    #expect(scratch.files.count == 2)
  }

  @Test func cancelDeletesOnlyWhatWasNotEmitted() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record([.microphone, .system], chunkSeconds: 2, in: scratch)
    sources[.microphone]?.play(Sound.tone(3.5), at: 0)
    sources[.system]?.play(Sound.tone(1), at: 0)

    var stream = recording.chunks.makeAsyncIterator()
    let emitted = try #require(await stream.next())
    #expect(emitted.track == .microphone)

    await recording.cancel()
    #expect(await stream.next() == nil)
    // The emitted file stays; the two half-written ones are gone.
    #expect(scratch.files == [emitted.url.lastPathComponent])
    #expect(await recording.levels.all().isEmpty == false)
    #expect(sources.values.allSatisfy { $0.stopCount == 1 })

    await recording.cancel()
    await recording.stop()
    #expect(scratch.files.count == 1)
  }

  @Test func manyCallersCanStopAtOnce() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(in: scratch)
    sources[.microphone]?.play(Sound.tone(1), at: 0)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 { group.addTask { await recording.stop() } }
    }
    #expect(await recording.chunks.all().count == 1)
    #expect(sources[.microphone]?.stopCount == 1)
  }

  @Test func droppingTheSessionStopsTheSourceAndCleansUp() async throws {
    let scratch = try Scratch()
    let source = ScriptedSource()
    do {
      let request = CaptureRequest(directory: scratch.url, chunkSeconds: 30)
      let recording = try Recording.start(request, sources: [.microphone: source], origin: 0)
      source.play(Sound.tone(1), at: 0)
      // Wait until the sound has been taken in.
      var levels = recording.levels.makeAsyncIterator()
      _ = await levels.next()
    }
    // Clean-up follows as soon as the writer queue lets go of the session.
    for _ in 0..<200 where source.stopCount == 0 || !scratch.files.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(source.stopCount == 1)
    #expect(scratch.files.isEmpty)
  }

  @Test func aSourceThatCannotStartLeavesNothingRunning() async throws {
    let scratch = try Scratch()
    let microphone = ScriptedSource()
    let system = ScriptedSource(failure: .permissionDenied(.systemAudio))
    let request = CaptureRequest(tracks: [.microphone, .system], directory: scratch.url)
    #expect(throws: WisperError.permissionDenied(.systemAudio)) {
      try Recording.start(request, sources: [.microphone: microphone, .system: system], origin: 0)
    }
    #expect(microphone.stopCount == 1)
    #expect(scratch.files.isEmpty)
  }

  @Test func aSecondCaptureInTheSameFolderKeepsTheFirstFiles() async throws {
    let scratch = try Scratch()
    for _ in 0..<2 {
      let (recording, sources) = try record(in: scratch)
      sources[.microphone]?.play(Sound.tone(0.5), at: 0)
      await recording.stop()
    }
    #expect(scratch.files == ["microphone-0000.m4a", "microphone-0001.m4a"])
  }

  @Test func levelsArriveAboutTwentyTimesASecondAndFollowLoudness() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record([.microphone, .system], in: scratch)
    let source = try #require(sources[.microphone])
    var time = source.play(Sound.hiss(0.5), at: 0)
    time = source.play(Sound.tone(1, amplitude: 0.05), at: time)
    source.play(Sound.tone(1, amplitude: 0.5), at: time)
    // The system track is loud all along, and must not move the meter.
    sources[.system]?.play(Sound.tone(2.5, amplitude: 0.9), at: 0)
    await recording.stop()

    let levels = await recording.levels.all()
    #expect((48...51).contains(levels.count))
    #expect(levels.allSatisfy { (0...1).contains($0) })
    let quiet = levels[2..<8].max() ?? 1
    let speech = levels[15..<28].min() ?? 0
    let loud = levels[35..<48].min() ?? 0
    #expect(quiet < 0.1)
    #expect(speech > 0.45 && speech < 0.75)
    #expect(loud > speech + 0.2)
  }

  @Test func meterValuesFromOneBufferAreSpreadOutNotBunched() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record(in: scratch)
    let clock = ContinuousClock()
    let start = clock.now
    // Sound arrives all at once here, as it does in bunches from a real
    // device. It holds three meter values (and a little towards a fourth).
    sources[.microphone]?.play(Sound.tone(0.19), at: 0)
    var levels = recording.levels.makeAsyncIterator()
    _ = await levels.next()
    _ = await levels.next()
    #expect(clock.now - start >= .milliseconds(45))
    await recording.cancel()
  }

  @Test func theSystemTrackDrivesTheMeterWhenThereIsNoMicrophone() async throws {
    let scratch = try Scratch()
    let (recording, sources) = try record([.system], in: scratch)
    sources[.system]?.play(Sound.tone(1), at: 0)
    await recording.stop()
    let levels = await recording.levels.all()
    #expect(levels.count >= 19)
    #expect((levels.last ?? 0) > 0.4)
  }
}
