import Foundation
import SpacesDomain

/// The names inside the data folder. `docs/data-format.md` describes them.
struct FolderLayout: Sendable {
  let root: URL

  static let settings = "settings.json"
  static let words = "dictionary.json"
  static let snippets = "snippets.json"
  static let dictations = "dictations.json"
  static let meetings = "meetings"
  static let meetingFile = "meeting.json"
  static let meetingNotes = "notes.md"

  var lockFile: URL { root.appendingPathComponent(".lock") }
  var dictationAudio: URL { root.appendingPathComponent("dictation-audio", isDirectory: true) }
  var meetingsFolder: URL { root.appendingPathComponent(FolderLayout.meetings, isDirectory: true) }

  func file(_ name: String) -> URL { root.appendingPathComponent(name) }

  func meetingFolder(_ name: String) -> URL {
    meetingsFolder.appendingPathComponent(name, isDirectory: true)
  }
}

/// Enough about a file to tell whether it changed since it was last read.
struct FileSignature: Hashable, Sendable {
  var device: Int64
  var inode: UInt64
  var size: Int64
  var modifiedSeconds: Int
  var modifiedNanoseconds: Int

  init(_ info: stat) {
    device = Int64(info.st_dev)
    inode = UInt64(info.st_ino)
    size = Int64(info.st_size)
    modifiedSeconds = Int(info.st_mtimespec.tv_sec)
    modifiedNanoseconds = Int(info.st_mtimespec.tv_nsec)
  }

  /// The signature of the file at `url`, or `nil` when there is no file there.
  static func of(_ url: URL) -> FileSignature? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return FileSignature(info)
  }
}

/// Reading and writing whole files, safely.
enum FileAccess {
  /// The bytes of a file together with the signature of exactly those bytes.
  /// `nil` when the file does not exist.
  static func read(_ url: URL) throws -> (data: Data, signature: FileSignature)? {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT || errno == ENOTDIR { return nil }
      throw SpacesError.storage("\(url.lastPathComponent) could not be opened. \(reason())")
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw SpacesError.storage("\(url.lastPathComponent) could not be read. \(reason())")
    }
    var data = Data()
    data.reserveCapacity(Int(info.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count > 0 {
        data.append(buffer, count: count)
      } else if count == 0 {
        break
      } else if errno != EINTR {
        throw SpacesError.storage("\(url.lastPathComponent) could not be read. \(reason())")
      }
    }
    return (data, FileSignature(info))
  }

  /// Replaces the file at `url` with `data` in one step: the new content is written to a
  /// hidden file next to it, flushed to disk, and renamed into place. A reader sees the old
  /// file or the new one, never a part of either.
  @discardableResult
  static func writeAtomically(_ data: Data, to url: URL) throws -> FileSignature {
    let name = url.lastPathComponent
    let folder = url.deletingLastPathComponent()
    let temporary = folder.appendingPathComponent(temporaryPrefix + "\(name)-\(UUID().uuidString)")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw SpacesError.storage("\(name) could not be saved. \(reason())")
    }
    var renamed = false
    defer {
      close(descriptor)
      if !renamed { unlink(temporary.path) }
    }
    protect(temporary)
    let written = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
        if count > 0 {
          offset += count
        } else if errno != EINTR {
          return false
        }
      }
      return true
    }
    var info = stat()
    guard written, flush(descriptor), fstat(descriptor, &info) == 0,
      rename(temporary.path, url.path) == 0
    else {
      throw SpacesError.storage("\(name) could not be saved. \(reason())")
    }
    renamed = true
    // Flush the folder too, so the rename itself survives a power cut.
    let folderDescriptor = open(folder.path, O_RDONLY | O_CLOEXEC)
    if folderDescriptor >= 0 {
      _ = flush(folderDescriptor)
      close(folderDescriptor)
    }
    return FileSignature(info)
  }

  /// Pushes a file's content to the disk and makes the disk keep the order of writes, so
  /// that after a power cut a file is whole: the old content or the new, never a mix.
  private static func flush(_ descriptor: Int32) -> Bool {
    // Not every kind of disk can keep the order. A plain flush is the next best thing.
    fcntl(descriptor, F_BARRIERFSYNC) == 0 || fsync(descriptor) == 0
  }

  /// Creates the folder (and the ones above it) when it is not there yet. Either way the
  /// folder ends up closed to other users of this computer.
  static func createFolder(_ url: URL) throws {
    if makePrivate(url) { return }
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw SpacesError.storage(
        "The folder \(url.lastPathComponent) could not be created. \(error.localizedDescription)"
      )
    }
    protect(url)
  }

  /// Makes the folder at `url` one that only its owner can open (mode 0700), when it is not
  /// already. Returns false when there is no folder there.
  @discardableResult
  static func makePrivate(_ url: URL) -> Bool {
    var info = stat()
    guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
    // A folder that cannot be changed (it belongs to somebody else) is used as it is.
    if info.st_mode & 0o777 != 0o700 { chmod(url.path, 0o700) }
    return true
  }

  /// Deletes a file or a folder with everything in it. Nothing there is not an error.
  static func remove(_ url: URL) throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch {
      throw SpacesError.storage(
        "\(url.lastPathComponent) could not be deleted. \(error.localizedDescription)"
      )
    }
  }

  /// Moves a file that cannot be read out of the way, as `<name>.corrupt-<timestamp>`, so
  /// nothing is lost and the app can carry on. Returns where it went.
  @discardableResult
  static func setAside(_ url: URL) throws -> URL {
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let stamp = Timestamp.string(from: now).filter { $0 != "-" && $0 != ":" }
    let base = url.lastPathComponent + ".corrupt-" + stamp
    let folder = url.deletingLastPathComponent()
    for attempt in 1...100 {
      let target = folder.appendingPathComponent(attempt == 1 ? base : "\(base)-\(attempt)")
      // RENAME_EXCL never replaces an earlier file with the same name.
      if renamex_np(url.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
      if errno != EEXIST { break }
    }
    throw SpacesError.storage(
      "\(url.lastPathComponent) cannot be read and could not be moved out of the way. \(reason())"
    )
  }

  /// Removes hidden files left behind, an hour or more ago, by a write that was cut short (a
  /// crash or a power cut).
  static func removeStaleTemporaryFiles(in folder: URL) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
    let cutoff = Int(Date().timeIntervalSince1970 - 3_600)
    for name in names where name.hasPrefix(temporaryPrefix) {
      let url = folder.appendingPathComponent(name)
      if let signature = FileSignature.of(url), signature.modifiedSeconds < cutoff { unlink(url.path) }
    }
  }

  /// Hidden files with this prefix are writes in progress.
  static let temporaryPrefix = ".tmp-"

  /// On iOS, keeps the item readable after the first unlock following a restart, so a
  /// recording that carries on with the screen locked can still be saved. macOS needs nothing.
  static func protect(_ url: URL) {
    #if !os(macOS)
      try? FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path
      )
    #endif
  }

  /// The system's reason for the last failed call, as a sentence.
  static func reason() -> String {
    let text = String(cString: strerror(errno))
    return text.hasSuffix(".") ? text : text + "."
  }
}

/// A lock on the data folder shared by every process that writes to it (the app and the
/// `spaces` tool). It is an advisory `flock` on `<root>/.lock`.
///
/// Not safe to share between threads: each `FileLibrary` owns one and uses it from its own queue.
final class FolderLock {
  private let layout: FolderLayout
  private var descriptor: Int32 = -1
  private var depth = 0

  init(layout: FolderLayout) {
    self.layout = layout
  }

  deinit {
    if descriptor >= 0 { close(descriptor) }
  }

  /// Runs `body` while holding the lock. May be nested.
  func withLock<Result>(_ body: () throws -> Result) throws -> Result {
    if depth == 0 { try acquire() }
    depth += 1
    defer {
      depth -= 1
      if depth == 0 { flock(descriptor, LOCK_UN) }
    }
    return try body()
  }

  private func acquire() throws {
    let path = layout.lockFile.path
    for _ in 0..<8 {
      if descriptor < 0 {
        try FileAccess.createFolder(layout.root)
        descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
          throw SpacesError.storage("The data folder could not be locked. \(FileAccess.reason())")
        }
      }
      try waitForLock()
      // If the folder was deleted and made again, this is a lock on a file nobody else can
      // see. Open the new one and try again.
      var mine = stat()
      var current = stat()
      if fstat(descriptor, &mine) == 0, stat(path, &current) == 0,
        mine.st_ino == current.st_ino, mine.st_dev == current.st_dev
      {
        return
      }
      close(descriptor)
      descriptor = -1
    }
    throw SpacesError.storage("The data folder could not be locked. It keeps changing.")
  }

  /// Waits for whoever holds the lock, but not for ever: a stuck process must not freeze
  /// this one. Holders keep the lock for a few milliseconds, so the wait is short pauses.
  private func waitForLock() throws {
    var waited: UInt32 = 0
    var pause: UInt32 = 200
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      if errno == EINTR { continue }
      guard errno == EWOULDBLOCK else {
        throw SpacesError.storage("The data folder could not be locked. \(FileAccess.reason())")
      }
      guard waited < FolderLock.patience else {
        throw SpacesError.storage("Another app is busy with your Spaces data. Try again in a moment.")
      }
      usleep(pause)
      waited += pause
      pause = min(pause * 2, 20_000)
    }
  }

  /// How long to wait for the lock, in microseconds.
  private static let patience: UInt32 = 15_000_000
}
