import AVFoundation

/// The short sounds that mark a dictation.
public enum SoundCue: Sendable, CaseIterable {
  /// Recording started: two soft notes going up.
  case start
  /// Recording ended: the same two notes going down.
  case stop
  /// Something went wrong: two low notes.
  case error
}

/// Plays the start, stop and error sounds.
///
/// The sounds are made in code when the player is created and kept ready, so
/// playing one starts within a few milliseconds. Create one player and keep it.
@MainActor
public final class SoundPlayer {
  private var players: [SoundCue: AVAudioPlayer] = [:]

  public init() {
    for cue in SoundCue.allCases {
      guard let player = try? AVAudioPlayer(data: Tone.wav(for: cue), fileTypeHint: AVFileType.wav.rawValue)
      else { continue }
      player.prepareToPlay()
      players[cue] = player
    }
  }

  /// Plays `cue`.
  public func play(_ cue: SoundCue) {
    guard let player = players[cue] else { return }
    player.currentTime = 0
    player.play()
  }
}

/// Makes the sounds: plain sums of sine waves with a soft start and a fading tail.
enum Tone {
  static let sampleRate = 44_100.0

  private struct Note {
    var frequency: Double
    var start: Double
    var length: Double
  }

  private static func notes(for cue: SoundCue) -> [Note] {
    switch cue {
    case .start:
      [Note(frequency: 587.33, start: 0, length: 0.14), Note(frequency: 880, start: 0.085, length: 0.2)]
    case .stop:
      [Note(frequency: 880, start: 0, length: 0.14), Note(frequency: 587.33, start: 0.085, length: 0.2)]
    case .error:
      [Note(frequency: 311.13, start: 0, length: 0.18), Note(frequency: 261.63, start: 0.15, length: 0.26)]
    }
  }

  /// The sound as samples between -1 and 1.
  static func samples(for cue: SoundCue) -> [Float] {
    let notes = notes(for: cue)
    let duration = notes.map { $0.start + $0.length }.max() ?? 0
    var samples = [Float](repeating: 0, count: Int(duration * sampleRate))
    for note in notes {
      let first = Int(note.start * sampleRate)
      let count = Int(note.length * sampleRate)
      for index in 0..<count where first + index < samples.count {
        let time = Double(index) / sampleRate
        let attack = min(1, time / 0.008)
        let tail = 0.5 * (1 + cos(.pi * time / note.length))
        let envelope = attack * tail * exp(-time * 9)
        let wave = sin(2 * .pi * note.frequency * time) + 0.18 * sin(4 * .pi * note.frequency * time)
        samples[first + index] += Float(0.3 * envelope * wave)
      }
    }
    return samples
  }

  /// The sound as a WAV file in memory (16-bit, one channel).
  static func wav(for cue: SoundCue) -> Data {
    let samples = samples(for: cue)
    let byteCount = samples.count * 2
    var data = Data(capacity: 44 + byteCount)
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + byteCount))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(UInt32(sampleRate))
    append(UInt32(sampleRate) * 2)
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(byteCount))
    for sample in samples {
      append(Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()))
    }
    return data
  }
}
