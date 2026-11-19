import AVFoundation
import Foundation
import WisperDomain

@testable import WisperAudio

/// A source the test plays by hand: the third adapter of `AudioSource`.
final class ScriptedSource: AudioSource, @unchecked Sendable {
  private let lock = NSLock()
  private var sink: SampleSink?
  private var stops = 0
  private let failure: WisperError?

  init(failure: WisperError? = nil) { self.failure = failure }

  var stopCount: Int { lock.withLock { stops } }

  func start(into sink: SampleSink) throws {
    if let failure { throw failure }
    lock.withLock { self.sink = sink }
  }

  func stop() {
    lock.withLock {
      stops += 1
      sink = nil
    }
  }

  /// Plays `samples` in 50 ms buffers, as a device would, starting at `time`.
  /// Returns the time just after the last sample.
  @discardableResult
  func play(_ samples: [Float], rate: Double = 48_000, at time: TimeInterval) -> TimeInterval {
    let sink = lock.withLock { self.sink }
    let size = Int(rate / 20)
    var start = 0
    while start < samples.count {
      let end = min(start + size, samples.count)
      sink?.deliver(Array(samples[start..<end]), rate, time + Double(start) / rate)
      start = end
    }
    return time + Double(samples.count) / rate
  }
}

enum Sound {
  /// A steady tone, about as loud as someone speaking when `amplitude` is 0.1.
  static func tone(_ seconds: Double, rate: Double = 48_000, amplitude: Float = 0.1) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 2 * .pi * 440 / Float(rate)) }
  }

  /// Nothing at all.
  static func silence(_ seconds: Double, rate: Double = 48_000) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * rate))
  }

  /// A quiet room: faint hiss, well below speech.
  static func hiss(_ seconds: Double, rate: Double = 48_000) -> [Float] {
    var generator = SystemRandomNumberGenerator()
    return (0..<Int(seconds * rate)).map { _ in Float.random(in: -0.002...0.002, using: &generator) }
  }
}

/// A fresh empty folder, removed when the value goes away.
final class Scratch {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("wisper-audio-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  var files: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
  }
}

/// What a finished file really holds, read back from disk.
struct Decoded {
  var sampleRate: Double
  var channels: Int
  var samples: [Float]

  var seconds: Double { Double(samples.count) / sampleRate }

  init(_ url: URL) throws {
    let file = try AVAudioFile(forReading: url)
    sampleRate = file.fileFormat.sampleRate
    channels = Int(file.fileFormat.channelCount)
    let capacity = AVAudioFrameCount(file.length)
    guard capacity > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)
    else {
      samples = []
      return
    }
    try file.read(into: buffer)
    let count = Int(buffer.frameLength)
    samples = buffer.floatChannelData.map { Array(UnsafeBufferPointer(start: $0[0], count: count)) } ?? []
  }

  /// Loudness (RMS) of the part between two times.
  func loudness(from start: Double, to end: Double) -> Float {
    let range = max(0, Int(start * sampleRate))..<min(samples.count, Int(end * sampleRate))
    guard !range.isEmpty else { return 0 }
    let energy = samples[range].reduce(Float(0)) { $0 + $1 * $1 }
    return (energy / Float(range.count)).squareRoot()
  }
}

extension AsyncStream {
  /// Everything the stream holds, once it has ended.
  func all() async -> [Element] {
    var result: [Element] = []
    for await element in self { result.append(element) }
    return result
  }
}
