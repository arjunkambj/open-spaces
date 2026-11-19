import AVFoundation

// The seam inside this package: where a track's sound comes from.
//
//   AudioSource -> MicrophoneSource   (AVAudioEngine input)
//               -> SystemTapSource    (Core Audio process tap, macOS)
//               -> a scripted source in the tests
//
// Everything after the source (resampling, cutting into files, encoding,
// loudness) is the same for every adapter and lives in `Recording`.

/// Where a source sends its sound.
struct SampleSink: Sendable {
  /// Hands over a run of mono samples (-1...1).
  ///
  /// - Parameters:
  ///   - samples: The sound, one channel.
  ///   - sampleRate: Samples per second. May change between calls (a new device).
  ///   - time: When the first sample was captured, in `HostClock` seconds.
  ///
  /// Never blocks: the work is queued. Not for use on a real-time audio thread
  /// (it allocates); a source that runs on one must hop off it first.
  let deliver: @Sendable (_ samples: [Float], _ sampleRate: Double, _ time: TimeInterval) -> Void
}

/// One track's supply of sound.
protocol AudioSource: AnyObject, Sendable {
  /// Starts sending sound to `sink` and keeps going, across device changes,
  /// until `stop()`. Throws `WisperError` when it cannot start at all.
  func start(into sink: SampleSink) throws
  /// Stops sending. Sound already captured is delivered before this returns.
  /// Safe to call twice.
  func stop()
}

/// The clock every track is timed against, so two tracks line up.
enum HostClock {
  /// Seconds on the machine's steady clock.
  static func now() -> TimeInterval {
    AVAudioTime.seconds(forHostTime: mach_absolute_time())
  }
}
