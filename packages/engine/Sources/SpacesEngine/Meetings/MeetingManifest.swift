import AudioToolbox
import Foundation
import SpacesDomain

/// The engine's own record of a meeting's audio, kept next to the audio files.
///
/// It lists every chunk capture has finished, where it sits in the meeting and what was heard in
/// it. That is what lets a meeting be finished after the app quit or a transcription failed.
///
/// The audio files are the truth and the manifest is a record of them: `load` adds every audio
/// file the record does not list, so a manifest that is missing, cut off or out of date never
/// hides a recording.
struct MeetingManifest: Codable, Equatable, Sendable {
  static let fileName = "manifest.json"

  struct Chunk: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
      /// Not transcribed yet.
      case pending
      /// Transcribed. `segments` holds what was heard, which may be nothing.
      case done
      /// Every attempt failed. Waits for a retry.
      case failed
    }

    /// File name inside the meeting's audio folder.
    var file: String
    var track: AudioTrack
    /// Seconds from the start of the meeting.
    var offset: TimeInterval
    var duration: TimeInterval
    var state: State = .pending
    /// What was heard, with times counted from the start of the meeting.
    var segments: [TranscriptSegment] = []
  }

  /// A voice told apart on the system track, with a stretch of one chunk in which only that
  /// voice speaks. Every later system chunk is sent with these, so the same person keeps the
  /// same name from chunk to chunk.
  struct Voice: Codable, Equatable, Sendable {
    /// The name the transcript gives the voice: "Speaker 1".
    var name: String
    /// The chunk the sample is in, and where in it, in seconds from the start of that file.
    var file: String
    var start: TimeInterval
    var end: TimeInterval
  }

  var chunks: [Chunk] = []
  /// Set once audio was found that nobody can read: the file that was being written when the
  /// app closed. That part of the meeting is gone, and the meeting has to say so.
  var lostAudio: Bool?
  /// The voices told apart so far, at most `Voices.mostKnown`. `nil` until the first is found.
  var voices: [Voice]?

  /// The manifest in `directory`, or `nil` when there is none that can be read.
  static func read(from directory: URL) -> MeetingManifest? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
    return try? JSONDecoder().decode(MeetingManifest.self, from: data)
  }

  /// What is known about the audio in `directory`: the manifest when it can be read, plus every
  /// audio file in the folder that it does not list, as a chunk still to be transcribed.
  ///
  /// A file's track and number come from its name (`<track>-<number>.m4a`) and its length from
  /// the file. Where it sits in the meeting is not written anywhere else, so it is taken to
  /// follow the chunk before it on the same track: the best guess there is.
  ///
  /// The file that was being written when the app closed cannot be read. Capture keeps a plain
  /// copy of it (`<track>-<number>.wav`) for exactly that case, and the copy takes its place.
  /// With no copy that sound is gone: the file is removed and `lostAudio` is set. A file that
  /// can be read but stops short of its own length is kept for what is in it, and `lostAudio`
  /// is set for what is not.
  ///
  /// Reads files, and writes the manifest when it found something, so call it away from the
  /// main actor. Not for a folder that is being recorded into: the file still being written
  /// would be taken for one that was left behind.
  static func load(from directory: URL) -> MeetingManifest {
    // Recordings are private: only the user's own account may read them.
    chmod(directory.path, 0o700)
    var manifest = read(from: directory) ?? MeetingManifest()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    // Left behind by a write that was cut short.
    for name in names where name.hasPrefix(temporaryPrefix) {
      unlink(directory.appendingPathComponent(name).path)
    }

    let listed = Set(manifest.chunks.map(\.file))
    let present = Set(names)
    var found: [(file: AudioFileName, length: TimeInterval)] = []
    var leftovers: [String] = []
    var lost = false
    func length(of name: String) -> TimeInterval? {
      guard present.contains(name), let audio = AudioFacts(directory.appendingPathComponent(name))
      else { return nil }
      if audio.isCutShort { lost = true }
      return audio.seconds
    }
    for file in names.compactMap(AudioFileName.init) {
      chmod(directory.appendingPathComponent(file.name).path, 0o600)
      guard !listed.contains(file.name) else { continue }
      if !canBeOpened(directory.appendingPathComponent(file.name)) {
        // Not even its bytes can be read right now, which says nothing about what is in it.
        // It stays, as a chunk still to be transcribed.
        found.append((file, 0))
      } else if !file.isCopy {
        if let length = length(of: file.name) {
          found.append((file, length))
        } else {
          // Never closed. Its copy, judged in its own turn, stands in for it. With no copy
          // there is nothing left of this part.
          leftovers.append(file.name)
          if !present.contains(file.twin) { lost = true }
        }
      } else if listed.contains(file.twin) || length(of: file.twin) != nil {
        // The file it copies was finished after all.
        leftovers.append(file.name)
      } else if let length = length(of: file.name) {
        // Less than the transcriber accepts is as good as nothing.
        if length >= shortestChunk { found.append((file, length)) } else { leftovers.append(file.name) }
      } else {
        leftovers.append(file.name)
        lost = true
      }
    }
    guard !found.isEmpty || !leftovers.isEmpty else { return manifest }

    // In the order they were recorded, the two tracks side by side.
    found.sort { ($0.file.number, $0.file.track.rawValue) < ($1.file.number, $1.file.track.rawValue) }
    for (file, length) in found {
      let before = manifest.chunks
        .filter { chunk in
          guard chunk.track == file.track, let earlier = AudioFileName(chunk.file) else { return false }
          return earlier.number < file.number
        }
        .max { $0.offset + $0.duration < $1.offset + $1.duration }
      manifest.chunks.append(
        Chunk(
          file: file.name,
          track: file.track,
          offset: before.map { $0.offset + $0.duration } ?? 0,
          duration: length
        )
      )
    }
    if lost { manifest.lostAudio = true }
    // Written down before anything is removed, so a second crash right here loses nothing more
    // and cannot hide that a part is gone.
    if !found.isEmpty || lost { try? manifest.write(to: directory) }
    for name in leftovers { unlink(directory.appendingPathComponent(name).path) }
    return manifest
  }

  /// Replaces the manifest in `directory` in one step: the new content goes to a hidden file
  /// next to it, is flushed to disk and renamed into place. After a crash or a power cut the
  /// file is the old manifest or the new one, never a part of either.
  func write(to directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(self)

    let target = directory.appendingPathComponent(MeetingManifest.fileName)
    let temporary = directory.appendingPathComponent(
      MeetingManifest.temporaryPrefix + UUID().uuidString
    )
    // Private from the first byte: only the user's own account may read it.
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw MeetingManifest.notSaved() }
    var renamed = false
    defer {
      close(descriptor)
      if !renamed { unlink(temporary.path) }
    }
    #if !os(macOS)
      // Stays writable while the screen is locked, like the rest of a meeting that is being recorded.
      try? FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: temporary.path
      )
    #endif
    let written = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
      guard let base = bytes.baseAddress else { return true }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, base + offset, bytes.count - offset)
        if count > 0 {
          offset += count
        } else if errno != EINTR {
          return false
        }
      }
      return true
    }
    guard written, MeetingManifest.flush(descriptor), rename(temporary.path, target.path) == 0 else {
      throw MeetingManifest.notSaved()
    }
    renamed = true
    // Flush the folder too, so the rename itself survives a power cut.
    let folder = open(directory.path, O_RDONLY | O_CLOEXEC)
    if folder >= 0 {
      _ = MeetingManifest.flush(folder)
      close(folder)
    }
  }

  /// Hidden files with this prefix are manifest writes in progress.
  private static let temporaryPrefix = ".tmp-\(fileName)-"

  /// Pushes a file's content to the disk and makes the disk keep the order of writes.
  private static func flush(_ descriptor: Int32) -> Bool {
    // Not every kind of disk can keep the order. A plain flush is the next best thing.
    fcntl(descriptor, F_BARRIERFSYNC) == 0 || fsync(descriptor) == 0
  }

  private static func notSaved() -> SpacesError {
    .storage("The record of this meeting's audio could not be saved. \(String(cString: strerror(errno))).")
  }

  /// The shortest audio the transcriber accepts, in seconds.
  private static let shortestChunk = 0.1

  /// Whether the file's bytes can be read at all, whatever they are.
  private static func canBeOpened(_ url: URL) -> Bool {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var byte: UInt8 = 0
    return Darwin.read(descriptor, &byte, 1) >= 0
  }
}

/// What an audio file says about itself, without decoding it.
private struct AudioFacts {
  /// How long the audio is, in seconds.
  var seconds: TimeInterval
  /// Whether the file ends before the audio it lists does: the end of it is missing.
  var isCutShort: Bool

  /// `nil` when the file cannot be opened as audio.
  init?(_ url: URL) {
    var file: AudioFileID?
    guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
    defer { AudioFileClose(file) }
    var seconds: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &seconds) == noErr,
      seconds.isFinite, seconds >= 0
    else { return nil }
    self.seconds = seconds

    var (start, count) = (Int64(0), Int64(0))
    var info = stat()
    size = UInt32(MemoryLayout<Int64>.size)
    let known =
      AudioFileGetProperty(file, kAudioFilePropertyDataOffset, &size, &start) == noErr
      && AudioFileGetProperty(file, kAudioFilePropertyAudioDataByteCount, &size, &count) == noErr
      && stat(url.path, &info) == 0
    isCutShort = known && start + count > Int64(info.st_size)
  }
}

/// The name capture gives an audio file: `<track>-<number>.m4a`, or `<track>-<number>.wav` for
/// the plain copy it keeps of a file that is still being written.
private struct AudioFileName {
  private static let finished = ".m4a"
  private static let copy = ".wav"

  var name: String
  var track: AudioTrack
  var number: Int
  /// Whether this is the plain copy of a file, not the file itself.
  var isCopy: Bool
  /// The other file of the pair: the copy's `.m4a`, or the `.m4a`'s copy.
  var twin: String

  init?(_ name: String) {
    let isCopy = name.hasSuffix(AudioFileName.copy)
    guard isCopy || name.hasSuffix(AudioFileName.finished) else { return nil }
    let stem = name.dropLast(4)
    let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, let track = AudioTrack(rawValue: String(parts[0])),
      let number = Int(parts[1]), number >= 0
    else { return nil }
    self.name = name
    self.track = track
    self.number = number
    self.isCopy = isCopy
    twin = stem + (isCopy ? AudioFileName.finished : AudioFileName.copy)
  }
}
