import AVFoundation
import Foundation
import Testing
import WisperDomain

@testable import WisperAudio

@Suite struct LevelTests {
  @Test func theMeterIsScaledForEarsNotForVolts() {
    // Room noise sits at the bottom, a shout at the top.
    #expect(LevelMeter.scale(rms: 0) == 0)
    #expect(LevelMeter.scale(rms: 0.001) == 0)
    #expect(LevelMeter.scale(rms: 1) == 1)
    #expect(LevelMeter.scale(rms: 0.5) == 1)
    // Ordinary speech (about -30 dBFS) is near the middle, not stuck near zero
    // as it would be on a straight scale (0.03).
    let speech = LevelMeter.scale(rms: 0.0316)
    #expect(speech > 0.5 && speech < 0.6)
    // Louder always reads higher.
    let steps: [Float] = [0.002, 0.005, 0.01, 0.03, 0.1, 0.3]
    let levels = steps.map(LevelMeter.scale)
    #expect(levels == levels.sorted())
    #expect(Set(levels).count == steps.count)
  }

  @Test func theMeterEasesDownInsteadOfDropping() {
    var meter = LevelMeter()
    let loud = meter.add(rms: 0.5, count: 800)
    let after = meter.add(rms: 0, count: 800)
    #expect(loud == 1)
    #expect(after != nil && after! < 1 && after! > 0.8)
    // A value comes out only once 50 ms of sound is in.
    #expect(meter.add(rms: 0.3, count: 400) == nil)
    #expect(meter.add(rms: 0.3, count: 400) != nil)
  }
}

@Suite struct ResamplerTests {
  private func loudness(_ samples: ArraySlice<Float>) -> Float {
    (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
  }

  private func tone(_ frequency: Double, seconds: Double, rate: Double) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(0.1 * sin(2 * Double.pi * frequency * Double($0) / rate)) }
  }

  /// Runs `input` through in buffers of `size`, as a device would deliver it.
  private func resample(_ input: [Float], rate: Double, size: Int) -> (all: [Float], perCall: [Int]) {
    var resampler = Resampler(inputRate: rate)
    var all: [Float] = []
    var perCall: [Int] = []
    for start in stride(from: 0, to: input.count, by: size) {
      let out = resampler.convert(Array(input[start..<min(start + size, input.count)]))
      perCall.append(out.count)
      all += out
    }
    all += resampler.finish()
    return (all, perCall)
  }

  @Test(arguments: [8_000.0, 24_000, 32_000, 44_100, 48_000, 96_000])
  func keepsLengthAndLoudness(rate: Double) {
    let result = resample(tone(440, seconds: 2, rate: rate), rate: rate, size: Int(rate / 10))
    #expect(result.all.count == 32_000)
    #expect(abs(loudness(result.all[8_000..<24_000]) - 0.0707) < 0.0005)
  }

  @Test(arguments: [480, 2_400, 4_410, 4_800, 9_600])
  func givesBackAllItCanOnEveryCall(size: Int) {
    // The system's own converter keeps up to 80 ms back with 4,800-sample
    // buffers. This one never holds back more than a millisecond or so.
    let result = resample(tone(440, seconds: 2, rate: 48_000), rate: 48_000, size: size)
    // (The last buffer may be a short one, so it is left out.)
    for count in result.perCall.dropFirst().dropLast() { #expect(abs(count - size / 3) <= 1) }
    #expect(abs((result.perCall.first ?? 0) - size / 3) <= 20)
    #expect(result.all.count == 32_000)
  }

  @Test func theResultDoesNotDependOnHowTheSoundWasSplitUp() {
    let input = tone(1_000, seconds: 0.5, rate: 44_100)
    let whole = resample(input, rate: 44_100, size: input.count).all
    let pieces = resample(input, rate: 44_100, size: 441).all
    #expect(whole.count == pieces.count)
    #expect(zip(whole, pieces).allSatisfy { abs($0 - $1) < 0.000_01 })
  }

  @Test func keepsSpeechFrequenciesAndRemovesWhatWouldFoldBack() {
    // Well inside the speech range: untouched.
    for frequency in [200.0, 1_000, 3_000, 6_000] {
      let out = resample(tone(frequency, seconds: 1, rate: 48_000), rate: 48_000, size: 4_800).all
      #expect(abs(loudness(out[4_000..<12_000]) - 0.0707) < 0.001)
    }
    // Above what 16 kHz can hold: gone (more than 60 dB down), not turned into a false tone.
    for frequency in [9_500.0, 12_000, 20_000] {
      let out = resample(tone(frequency, seconds: 1, rate: 48_000), rate: 48_000, size: 4_800).all
      #expect(loudness(out[4_000..<12_000]) < 0.000_07)
    }
  }

  @Test func passesSixteenKilohertzStraightThrough() {
    var resampler = Resampler(inputRate: 16_000)
    let input = tone(440, seconds: 0.1, rate: 16_000)
    #expect(resampler.convert(input) == input)
    #expect(resampler.finish().isEmpty)
  }
}

@Suite struct DeviceTests {
  @Test func listingMicrophonesIsSafeAndConsistent() async {
    let devices = await SystemAudioCapture().microphones()
    #expect(devices.filter(\.isDefault).count <= 1)
    #expect(Set(devices.map(\.id)).count == devices.count)
    #expect(devices.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
    #if os(macOS)
      // Devices the audio system builds for its own use are not offered.
      #expect(devices.allSatisfy { !$0.id.hasPrefix("CADefaultDeviceAggregate") })
    #endif
  }

  @Test func startRefusesAMissingFolderAndAnEmptyRequest() async {
    let capture = SystemAudioCapture()
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wisper-none-\(UUID().uuidString)"
    )
    await #expect(throws: WisperError.captureFailed("The folder for the recording is missing.")) {
      _ = try await capture.start(CaptureRequest(directory: missing))
    }
    await #expect(throws: WisperError.captureFailed("Nothing was chosen to record.")) {
      _ = try await capture.start(
        CaptureRequest(tracks: [], directory: FileManager.default.temporaryDirectory)
      )
    }
  }
}

#if os(macOS)
  @Suite struct SampleRelayTests {
    /// Builds the kind of buffer list the audio thread hands over and passes it to `body`.
    private func withBuffers(
      _ channels: [[Float]],
      interleaved: Bool,
      _ body: (UnsafePointer<AudioBufferList>) -> Void
    ) {
      let frames = channels[0].count
      let list = AudioBufferList.allocate(maximumBuffers: interleaved ? 1 : channels.count)
      var storage: [UnsafeMutablePointer<Float>] = []
      defer {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
      }
      if interleaved {
        let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels.count)
        storage.append(data)
        for frame in 0..<frames {
          for (index, channel) in channels.enumerated() {
            data[frame * channels.count + index] = channel[frame]
          }
        }
        list[0] = AudioBuffer(
          mNumberChannels: UInt32(channels.count),
          mDataByteSize: UInt32(frames * channels.count * 4),
          mData: data
        )
      } else {
        for (index, channel) in channels.enumerated() {
          let data = UnsafeMutablePointer<Float>.allocate(capacity: frames)
          storage.append(data)
          data.update(from: channel, count: frames)
          list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: data)
        }
      }
      body(UnsafePointer(list.unsafeMutablePointer))
    }

    private func drained(_ relay: SampleRelay) -> (samples: [Float], stamps: [(UInt64, Int)]) {
      var samples: [Float] = []
      var stamps: [(UInt64, Int)] = []
      relay.drain { block, hostTime, offset in
        samples += block
        stamps.append((hostTime, offset))
      }
      return (samples, stamps)
    }

    @Test func mixesChannelsToMonoWhateverTheLayout() throws {
      let left: [Float] = [1, 0.5, 0, -1]
      let right: [Float] = [0, 0.5, 1, -1]
      for interleaved in [true, false] {
        let relay = try #require(SampleRelay(blocks: 4, blockFrames: 8))
        withBuffers([left, right], interleaved: interleaved) { relay.write($0, hostTime: 7) }
        let result = drained(relay)
        #expect(result.samples == [0.5, 0.5, 0.5, -1])
        #expect(result.stamps.count == 1)
        #expect(result.stamps.first?.0 == 7 && result.stamps.first?.1 == 0)
      }
    }

    @Test func splitsABigBufferAcrossBlocksAndKeepsItsPlace() throws {
      let relay = try #require(SampleRelay(blocks: 4, blockFrames: 8))
      let ramp = (0..<20).map(Float.init)
      withBuffers([ramp], interleaved: false) { relay.write($0, hostTime: 99) }
      let result = drained(relay)
      #expect(result.samples == ramp)
      #expect(result.stamps.map(\.1) == [0, 8, 16])
      #expect(result.stamps.allSatisfy { $0.0 == 99 })
    }

    @Test func dropsNewSoundWhenFullThenRecovers() throws {
      let relay = try #require(SampleRelay(blocks: 2, blockFrames: 4))
      let ramp = (0..<12).map(Float.init)
      withBuffers([ramp], interleaved: false) { relay.write($0, hostTime: 1) }
      // Only two blocks exist, so the last four samples had nowhere to go.
      #expect(drained(relay).samples == Array(ramp[0..<8]))
      withBuffers([ramp], interleaved: false) { #expect(relay.write($0, hostTime: 1) == false) }
      _ = drained(relay)
      // Draining gave the blocks back.
      withBuffers([[5, 6]], interleaved: false) { relay.write($0, hostTime: 2) }
      #expect(drained(relay).samples == [5, 6])
    }

    @Test func oneWriterAndOneReaderOnDifferentThreadsKeepEverySampleInOrder() async throws {
      // Few blocks, so they go round many times between the two threads.
      let relay = try #require(SampleRelay(blocks: 16, blockFrames: 128))
      let total = 6_000
      let writer = Thread {
        var next: Float = 0
        for _ in 0..<total {
          let buffer = (0..<128).map { _ -> Float in
            next += 1
            return next
          }
          self.withBuffers([buffer], interleaved: false) { list in
            // A real audio thread would drop the buffer when the relay is
            // full. Waiting instead lets the test demand every sample back.
            while !relay.write(list, hostTime: 0) { usleep(50) }
          }
        }
      }
      writer.start()

      var received: [Float] = []
      received.reserveCapacity(total * 128)
      let deadline = Date().addingTimeInterval(30)
      while received.count < total * 128, Date() < deadline {
        relay.drain { block, _, _ in received += block }
        await Task.yield()
      }
      #expect(received.count == total * 128)
      #expect(received.first == 1)
      #expect(zip(received, received.dropFirst()).allSatisfy { $1 == $0 + 1 })
    }
  }
#endif
