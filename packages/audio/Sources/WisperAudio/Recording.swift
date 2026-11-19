import Foundation
import WisperDomain

/// A capture in progress: takes sound from one source per track and turns it
/// into files and loudness values.
///
/// `@unchecked Sendable`: every mutable property is read and written on
/// `queue` only (and in `deinit`, when nothing else can reach the object).
/// The two stream continuations are `Sendable` themselves.
final class Recording: CaptureSession, @unchecked Sendable {
  let levels: AsyncStream<Float>
  let chunks: AsyncStream<AudioChunk>
  let frames: AsyncStream<AudioFrames>

  /// How many runs of live sound may wait for their reader: a few minutes' worth. Past that
  /// the newest are dropped, so a reader that has stopped reading cannot use up the memory.
  static let mostFramesWaiting = 4_000

  private enum Phase { case recording, ending, ended }

  private let levelContinuation: AsyncStream<Float>.Continuation
  private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
  private let frameContinuation: AsyncStream<AudioFrames>.Continuation
  /// The writer queue: resampling, encoding and file work all happen here.
  private let queue = DispatchQueue(
    label: "openwisper.audio.writer",
    qos: .userInitiated,
    autoreleaseFrequency: .workItem
  )
  private var writers: [AudioTrack: TrackWriter] = [:]
  private var sources: [any AudioSource] = []
  private var phase = Phase.recording
  private var waiters: [CheckedContinuation<Void, Never>] = []
  /// Meter values waiting for their turn.
  private var pendingLevels: [Float] = []
  private var isPacing = false

  /// Starts recording `request` from `sources` (one per requested track). This moment counts
  /// as second 0 of the capture.
  ///
  /// - Throws: Whatever a source throws when it cannot start. Nothing is left running.
  static func start(_ request: CaptureRequest, sources: [AudioTrack: any AudioSource]) throws -> Recording {
    let recording = Recording(request: request, tracks: Set(sources.keys), origin: HostClock.now())
    var running: [any AudioSource] = []
    do {
      for track in AudioTrack.allCases {
        guard let source = sources[track] else { continue }
        // Listed before it starts, so a source that fails half-way is still stopped.
        running.append(source)
        try source.start(into: recording.sink(for: track))
      }
    } catch {
      for source in running { source.stop() }
      recording.queue.sync { recording.finalize(emitting: false) }
      throw error
    }
    recording.queue.sync { recording.sources = running }
    return recording
  }

  private init(request: CaptureRequest, tracks: Set<AudioTrack>, origin: TimeInterval) {
    // A meter that is not being watched keeps only the newest few seconds.
    (levels, levelContinuation) = AsyncStream.makeStream(
      of: Float.self,
      bufferingPolicy: .bufferingNewest(64)
    )
    (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
    (frames, frameContinuation) = AsyncStream.makeStream(
      of: AudioFrames.self,
      bufferingPolicy: .bufferingOldest(Recording.mostFramesWaiting)
    )
    let metered: AudioTrack = tracks.contains(.microphone) ? .microphone : .system
    // Live sound is the file's sound, which only holds when there is one file.
    let handsOver = request.liveFrames && request.chunkSeconds == nil
    if !handsOver { frameContinuation.finish() }
    for track in tracks {
      let chunks = chunkContinuation
      let frames = frameContinuation
      writers[track] = TrackWriter(
        track: track,
        directory: request.directory,
        origin: origin,
        chunkSeconds: request.chunkSeconds,
        emit: { chunks.yield($0) },
        report: track == metered ? { [weak self] in self?.pace($0) } : nil,
        live: track == metered && handsOver
          ? { frames.yield(AudioFrames(samples: $0, sampleRate: Encoding.sampleRate)) } : nil
      )
    }
  }

  deinit {
    // Dropped without `stop()` or `cancel()`: treat it as a cancel.
    for source in sources { source.stop() }
    for writer in writers.values { writer.discard() }
    levelContinuation.finish()
    frameContinuation.finish()
    chunkContinuation.finish()
    for waiter in waiters { waiter.resume() }
  }

  func stop() async { await end(emitting: true) }

  func cancel() async { await end(emitting: false) }

  private func sink(for track: AudioTrack) -> SampleSink {
    SampleSink { [weak self, queue] samples, sampleRate, time in
      queue.async { [weak self] in
        guard let self, self.phase != .ended else { return }
        self.writers[track]?.append(samples, sampleRate: sampleRate, at: time)
      }
    }
  }

  /// Hands meter values out 50 ms apart. Sound arrives in buffers of 100 ms
  /// or more, so values come in bunches, and a meter fed in bunches moves in jerks.
  private func pace(_ level: Float) {
    pendingLevels.append(level)
    // Far behind (the machine stalled for a moment): catch up at once.
    while pendingLevels.count > 4 { levelContinuation.yield(pendingLevels.removeFirst()) }
    if !isPacing { releaseLevel() }
  }

  private func releaseLevel() {
    guard !pendingLevels.isEmpty else {
      isPacing = false
      return
    }
    levelContinuation.yield(pendingLevels.removeFirst())
    isPacing = true
    queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in self?.releaseLevel() }
  }

  private func end(emitting: Bool) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      queue.async {
        switch self.phase {
        case .ended:
          done.resume()
        case .ending:
          self.waiters.append(done)
        case .recording:
          self.phase = .ending
          self.waiters.append(done)
          let sources = self.sources
          self.sources = []
          // Each source hands over its last sound before `stop` returns. That
          // sound is queued behind this block, so finalising is queued after it.
          for source in sources { source.stop() }
          self.queue.async { self.finalize(emitting: emitting) }
        }
      }
    }
  }

  private func finalize(emitting: Bool) {
    for track in AudioTrack.allCases {
      guard let writer = writers[track] else { continue }
      if emitting { writer.finish() } else { writer.discard() }
    }
    writers = [:]
    phase = .ended
    for level in pendingLevels { levelContinuation.yield(level) }
    pendingLevels = []
    levelContinuation.finish()
    // Before the files: whoever waits for the last file has all of the live sound by then.
    frameContinuation.finish()
    chunkContinuation.finish()
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume() }
  }
}
