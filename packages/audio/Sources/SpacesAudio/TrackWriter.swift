import Accelerate
import Foundation
import SpacesDomain

/// Turns one track's samples into finished files: resamples to 16 kHz, cuts
/// into files, encodes, and measures loudness.
///
/// Not thread-safe: a `Recording` uses each writer on its own queue only.
final class TrackWriter {
  private enum Tuning {
    /// Samples are judged in 10 ms steps.
    static let step = 160
    /// A pause is 250 ms of quiet.
    static let pause = 4_000
    /// Below this loudness (about -60 dBFS) a step is always quiet.
    static let quietFloor: Float = 0.001
    /// A step is also quiet when it is this far below recent speech (about -16 dB).
    static let quietRatio: Float = 0.15
    /// Recent speech loudness halves in about 5 seconds.
    static let loudnessDecay: Float = 0.9986
    /// A peak below this (about -90 dBFS) means no signal at all: nothing is
    /// playing, or the microphone is muted. Even a silent room is far louder.
    static let silencePeak: Float = 0.000_03
    /// Sound arriving this much later than expected (100 ms) means some was lost.
    static let gap = 1_600
    /// Lost sound up to 2 seconds is filled with silence; more than that is skipped.
    static let longestFilledGap = 32_000
    /// How far (20 ms) the sample count may stray from the shared clock.
    static let drift = 320
    /// Files are padded with silence up to 0.1 seconds, the shortest OpenAI accepts.
    static let shortestFile = 1_600
  }

  private let track: AudioTrack
  private let directory: URL
  private let origin: TimeInterval
  /// Wanted file length in samples, or `nil` for one file.
  private let target: Int?
  /// How far either side of `target` a cut may land.
  private let slack: Int
  private let emit: (AudioChunk) -> Void
  private let report: ((Float) -> Void)?
  private let live: (([Float]) -> Void)?

  private var resampler: Resampler?
  /// 16 kHz samples waiting for a full step.
  private var carry: [Float] = []
  private var started = false
  /// `HostClock` time at which the next sample is due, if none goes missing.
  private var expected: TimeInterval?
  /// Timeline position (16 kHz samples since `origin`) of the next sample to store.
  private var position = 0
  /// Samples removed from the timeline, when sound was skipped in a one-file capture.
  private var skipped = 0
  private var open: EncodedFile?
  /// Timeline position of the open file's first sample.
  private var openStart = 0
  private var index: Int
  private var emitted = 0
  /// Samples judged since the open file began.
  private var judged = 0
  private var quietRun = 0
  private var loudness: Float = 0
  private var meter = LevelMeter()

  /// - Parameters:
  ///   - origin: `HostClock` time that counts as second 0 of the capture.
  ///   - chunkSeconds: Wanted file length, or `nil` for one file.
  ///   - emit: Called with each finished file.
  ///   - report: Called with loudness about 20 times a second, when wanted.
  ///   - live: Called with each run of samples as it goes into the file (16 kHz), when wanted.
  init(
    track: AudioTrack,
    directory: URL,
    origin: TimeInterval,
    chunkSeconds: TimeInterval?,
    emit: @escaping (AudioChunk) -> Void,
    report: ((Float) -> Void)?,
    live: (([Float]) -> Void)? = nil
  ) {
    self.track = track
    self.directory = directory
    self.origin = origin
    self.emit = emit
    self.report = report
    self.live = live
    if let chunkSeconds, chunkSeconds > 0 {
      let wanted = max(Tuning.step, Int(chunkSeconds * Encoding.sampleRate))
      target = wanted
      slack = min(Int(3 * Encoding.sampleRate), wanted / 5)
    } else {
      target = nil
      slack = 0
    }
    index = TrackWriter.firstFreeIndex(for: track, in: directory)
  }

  /// Takes a run of mono samples captured at `time`.
  func append(_ samples: [Float], sampleRate: Double, at time: TimeInterval) {
    guard !samples.isEmpty, sampleRate > 0 else { return }
    if let expected {
      // This sound starts later than the last one ended: some went missing.
      let missing = Int(((time - expected) * Encoding.sampleRate).rounded())
      if missing > Tuning.gap { bridge(missing) }
    }
    expected = time + Double(samples.count) / sampleRate

    // Where this sound sits on the shared clock. Counting samples alone would
    // creep away from that over a long recording, because no device keeps
    // perfect time, so the count is pulled back whenever it is 20 ms out.
    // Only the offsets of later files move; no sound is added or dropped.
    let arrival = max(0, Int(((time - origin) * Encoding.sampleRate).rounded()) - skipped)
    let drift = arrival - (position + carry.count)
    if !started || abs(drift) > Tuning.drift { position += drift }
    started = true

    if resampler?.inputRate != sampleRate {
      drainResampler()
      resampler = Resampler(inputRate: sampleRate)
    }
    if let converted = resampler?.convert(samples) { process(converted) }
  }

  /// Writes out what is left and emits the last file.
  func finish() {
    drainResampler()
    flushCarry()
    // One file was asked for, so there is one even when nothing was captured.
    if target == nil, open == nil, emitted == 0 { openFile() }
    closeFile()
  }

  /// Deletes the file being written.
  func discard() {
    resampler = nil
    carry = []
    open?.remove()
    open = nil
  }

  // MARK: Timeline

  /// Handles `missing` samples of lost sound (a device change, an interruption).
  private func bridge(_ missing: Int) {
    drainResampler()
    if missing <= Tuning.longestFilledGap {
      process([Float](repeating: 0, count: missing))
    } else if target != nil {
      // Start a new file after the hole, so no file carries minutes of nothing.
      flushCarry()
      closeFile()
    } else {
      // One file was asked for: join the two sides and leave the hole out.
      skipped += missing
    }
  }

  private func drainResampler() {
    guard var last = resampler else { return }
    resampler = nil
    process(last.finish())
  }

  // MARK: Cutting

  private func process(_ samples: [Float]) {
    guard !samples.isEmpty else { return }
    let block = carry.isEmpty ? samples : carry + samples
    var stored = 0
    var cursor = 0
    block.withUnsafeBufferPointer { all in
      while all.count - cursor >= Tuning.step {
        let step = UnsafeBufferPointer(rebasing: all[cursor..<cursor + Tuning.step])
        cursor += Tuning.step
        if endsFile(after: step) {
          store(UnsafeBufferPointer(rebasing: all[stored..<cursor]))
          stored = cursor
          closeFile()
        }
      }
      store(UnsafeBufferPointer(rebasing: all[stored..<cursor]))
    }
    carry = Array(block[cursor...])
  }

  /// Judges one step and says whether the file should end right after it.
  private func endsFile(after step: UnsafeBufferPointer<Float>) -> Bool {
    guard let base = step.baseAddress else { return false }
    var rms: Float = 0
    vDSP_rmsqv(base, 1, &rms, vDSP_Length(step.count))
    if let report, let level = meter.add(rms: rms, count: step.count) { report(level) }

    judged += step.count
    loudness = max(rms, loudness * Tuning.loudnessDecay)
    let isQuiet = rms < max(Tuning.quietFloor, loudness * Tuning.quietRatio)
    quietRun = isQuiet ? quietRun + step.count : 0

    guard let target else { return false }
    // No pause came: cut anyway.
    if judged >= target + slack { return true }
    // Close enough to the wanted length, and nobody is mid-word.
    return judged >= target - slack && quietRun >= Tuning.pause
  }

  private func flushCarry() {
    guard !carry.isEmpty else { return }
    let rest = carry
    carry = []
    rest.withUnsafeBufferPointer { store($0) }
  }

  // MARK: Files

  private func store(_ samples: UnsafeBufferPointer<Float>) {
    guard let base = samples.baseAddress, !samples.isEmpty else { return }
    defer { position += samples.count }

    if open == nil {
      if target != nil {
        var peak: Float = 0
        vDSP_maxmgv(base, 1, &peak, vDSP_Length(samples.count))
        // Nothing to hear yet: do not start a file with it.
        if peak < Tuning.silencePeak {
          judged = 0
          return
        }
      }
      openFile()
    }
    // The disk is full or the folder is gone: keep what was written so far.
    if let open, !open.write(samples) {
      closeFile()
    } else if let live {
      live(Array(samples))
    }
  }

  private func openFile() {
    let name = "\(track.rawValue)-\(String(format: "%04d", index)).m4a"
    // When cutting, the length is known to within the slack. Otherwise guess
    // a minute, which covers most dictations.
    let expected = target.map { Double($0 + slack) / Encoding.sampleRate + 1 } ?? 60
    // A file that is one of many is closed long before the capture ends, and until then the
    // app can be killed with it open, so its sound is kept in a plain copy as well.
    open = EncodedFile(
      url: directory.appendingPathComponent(name),
      expectedSeconds: expected,
      keepsCopy: target != nil
    )
    openStart = position
  }

  /// Closes the open file and emits it.
  private func closeFile() {
    judged = 0
    guard let open else { return }
    self.open = nil
    let missing = Tuning.shortestFile - open.frames
    if missing > 0 {
      [Float](repeating: 0, count: missing).withUnsafeBufferPointer { _ = open.write($0) }
    }
    guard open.frames > 0 else {
      open.remove()
      return
    }
    open.close()
    index += 1
    emitted += 1
    emit(
      AudioChunk(
        track: track,
        url: open.url,
        offset: Double(max(0, openStart)) / Encoding.sampleRate,
        duration: Double(open.frames) / Encoding.sampleRate
      )
    )
  }

  /// The lowest file number not yet used for `track`, so a second capture into
  /// the same folder never overwrites the first.
  private static func firstFreeIndex(for track: AudioTrack, in directory: URL) -> Int {
    let prefix = "\(track.rawValue)-"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    let used = names.compactMap { name -> Int? in
      // A `.wav` is the copy of a file that was never closed, found by a later run.
      guard name.hasPrefix(prefix), name.hasSuffix(".m4a") || name.hasSuffix(".wav") else { return nil }
      return Int(name.dropFirst(prefix.count).dropLast(4))
    }
    return (used.max() ?? -1) + 1
  }
}

/// Turns loudness into meter values, about 20 a second.
struct LevelMeter {
  /// Samples per meter value: 50 ms at 16 kHz.
  private static let window = 800
  /// The meter reads 0 at this loudness and below (room noise).
  private static let floorDB: Float = -55
  /// The meter reads 1 at this loudness and above (a raised voice, close up).
  private static let ceilingDB: Float = -10
  /// How far the meter may fall per value, so it eases down instead of flickering.
  private static let release: Float = 0.12

  private var energy: Float = 0
  private var count = 0
  private var shown: Float = 0

  /// Adds a step of sound. Returns a meter value each time 50 ms has been added.
  mutating func add(rms: Float, count added: Int) -> Float? {
    energy += rms * rms * Float(added)
    count += added
    guard count >= LevelMeter.window else { return nil }
    let level = LevelMeter.scale(rms: (energy / Float(count)).squareRoot())
    energy = 0
    count = 0
    shown = level >= shown ? level : max(level, shown - LevelMeter.release)
    return shown
  }

  /// Maps loudness (RMS, 0...1) to a meter position, 0...1.
  ///
  /// The scale is in decibels, the way ears work: ordinary speech
  /// (about -30 to -18 dBFS) lands around the middle to upper part of the meter.
  static func scale(rms: Float) -> Float {
    guard rms > 0 else { return 0 }
    let decibels = 20 * log10(rms)
    return min(1, max(0, (decibels - floorDB) / (ceilingDB - floorDB)))
  }
}
