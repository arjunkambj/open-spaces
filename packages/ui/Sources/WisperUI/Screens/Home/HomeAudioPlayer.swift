import AVFoundation
import Observation
import WisperDomain

/// Plays the kept audio of one dictation at a time.
///
/// Views read `playingID` and `progress`. Call `stop()` when the screen goes away.
@MainActor
@Observable
final class HomeAudioPlayer {
  /// The dictation whose audio is playing, or `nil`.
  private(set) var playingID: Dictation.ID?
  /// How far the audio has played, 0...1.
  private(set) var progress: Double = 0
  /// Seconds played so far.
  private(set) var elapsed: TimeInterval = 0

  @ObservationIgnored private var player: AVAudioPlayer?
  @ObservationIgnored private var ticker: Task<Void, Never>?
  /// A still picture for snapshots: it plays nothing and never changes.
  @ObservationIgnored private let isStill: Bool

  init() {
    isStill = false
  }

  /// A player that looks as if it were part-way through `id`, for snapshots. It plays nothing
  /// and stays that way.
  init(showing id: Dictation.ID, progress: Double, elapsed: TimeInterval) {
    isStill = true
    playingID = id
    self.progress = progress
    self.elapsed = elapsed
  }

  /// Plays `file` from the start, stopping whatever was playing. Throws when the file cannot be played.
  func play(_ id: Dictation.ID, file: URL) throws {
    guard !isStill else { return }
    stop()
    #if os(iOS)
      // Without this the ring/silent switch would mute the recording.
      let session = AVAudioSession.sharedInstance()
      if session.category != .playback && session.category != .playAndRecord {
        try? session.setCategory(.playback, mode: .default)
      }
      try? session.setActive(true)
    #endif
    let player = try AVAudioPlayer(contentsOf: file)
    guard player.play() else { throw WisperError.storage("The recording could not be played.") }
    self.player = player
    playingID = id
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, let self, let player = self.player else { return }
        guard player.isPlaying else {
          self.stop()
          return
        }
        self.elapsed = player.currentTime
        self.progress = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
      }
    }
  }

  func stop() {
    guard !isStill else { return }
    ticker?.cancel()
    ticker = nil
    player?.stop()
    player = nil
    playingID = nil
    progress = 0
    elapsed = 0
  }
}
