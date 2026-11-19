import Foundation
import WisperDomain

/// The meetings in the data folder, one folder each, with a copy kept in memory.
///
/// Finding out what changed costs one `stat` per meeting. A `meeting.json` is only read
/// again when its signature is new. Not safe to share between threads: `FileLibrary` uses it
/// from its own queue.
final class MeetingIndex {
  private struct Entry {
    /// The folder's name on disk. Normally the meeting's id in upper case.
    var folder: String
    /// `meeting.json` as the last look saw it.
    var observed: FileSignature
    /// The meeting last read or written, and the signature of the file it came from.
    var loaded: (signature: FileSignature, meeting: Meeting)?
  }

  private let layout: FolderLayout
  private let lock: FolderLock
  private var entries: [Meeting.ID: Entry] = [:]
  /// True once the whole meetings folder has been looked at.
  private var scanned = false
  private var sorted: [Meeting]?

  init(layout: FolderLayout, lock: FolderLock) {
    self.layout = layout
    self.lock = lock
  }

  // MARK: Reading

  /// Looks at every meeting folder without reading any meeting. Returns the meetings that
  /// somebody else added or edited since the last look, and whether anything changed at all
  /// (which includes meetings that went away).
  ///
  /// The first look has nothing to compare with. It reports a meeting it does not know
  /// only when `since` is given and the meeting was written at or after that moment.
  @discardableResult
  func scan(since: Date? = nil) -> (changed: Bool, edited: [Meeting.ID]) {
    let found = foldersOnDisk()
    var changed = false
    var edited: [Meeting.ID] = []
    if !scanned, let since {
      // A little slack, because file times and the clock do not tick together exactly.
      let moment = since.timeIntervalSince1970 - 0.01
      for (id, (_, signature)) in found where entries[id] == nil {
        let written = Double(signature.modifiedSeconds) + Double(signature.modifiedNanoseconds) / 1e9
        if written >= moment {
          changed = true
          edited.append(id)
        }
      }
    }
    for id in entries.keys where found[id] == nil {
      entries[id] = nil
      changed = true
    }
    for (id, (folder, signature)) in found {
      if var entry = entries[id] {
        entry.folder = folder
        if entry.observed != signature {
          entry.observed = signature
          changed = true
          edited.append(id)
        }
        if entry.loaded?.signature != signature { entry.loaded = nil }
        entries[id] = entry
      } else {
        entries[id] = Entry(folder: folder, observed: signature, loaded: nil)
        if scanned {
          changed = true
          edited.append(id)
        }
      }
    }
    scanned = true
    if changed { sorted = nil }
    return (changed, edited)
  }

  /// Every meeting, newest first. Call `scan()` first to pick up what changed on disk.
  func all() throws -> [Meeting] {
    if let sorted { return sorted }
    try loadMissing()
    let meetings = entries.values.compactMap { $0.loaded?.meeting }.sorted {
      // The id settles ties, so the order is the same every time.
      ($0.startedAt, $1.id.uuidString) > ($1.startedAt, $0.id.uuidString)
    }
    sorted = meetings
    return meetings
  }

  /// One meeting, read without looking at the others. `changed` is true when somebody else
  /// added, edited or removed it since the last look.
  func meeting(_ id: Meeting.ID) throws -> (meeting: Meeting?, changed: Bool) {
    let folder = entries[id]?.folder ?? id.uuidString
    let url = layout.meetingFolder(folder).appendingPathComponent(FolderLayout.meetingFile)
    var changed = false
    if let signature = FileSignature.of(url) {
      if var entry = entries[id] {
        if entry.observed != signature {
          entry.observed = signature
          changed = true
        }
        if entry.loaded?.signature != signature { entry.loaded = nil }
        entries[id] = entry
      } else {
        entries[id] = Entry(folder: folder, observed: signature, loaded: nil)
        changed = scanned
      }
    } else if entries.removeValue(forKey: id) != nil {
      changed = true
    }
    if changed { sorted = nil }
    guard entries[id] != nil else { return (nil, changed) }
    if entries[id]?.loaded == nil { try load([id]) }
    return (entries[id]?.loaded?.meeting, changed)
  }

  // MARK: Writing

  /// Writes `meeting.json` and `notes.md`, both in one step each.
  func save(_ meeting: Meeting) throws {
    try lock.withLock {
      let name = entries[meeting.id]?.folder ?? meeting.id.uuidString
      let folder = layout.meetingFolder(name)
      try FileAccess.createFolder(folder)
      FileAccess.removeStaleTemporaryFiles(in: folder)
      let signature = try FileAccess.writeAtomically(
        try LibraryJSON.encode(meeting),
        to: folder.appendingPathComponent(FolderLayout.meetingFile)
      )
      entries[meeting.id] = Entry(folder: name, observed: signature, loaded: (signature, meeting))
      sorted = nil
      try writeNotes(for: meeting, in: folder)
    }
  }

  /// Removes the meeting's folder with everything in it.
  func delete(_ id: Meeting.ID) throws {
    try lock.withLock {
      let folder = layout.meetingFolder(entries[id]?.folder ?? id.uuidString)
      entries[id] = nil
      sorted = nil
      // Out of sight in one step first, so nobody ever sees half a meeting.
      let trash = layout.meetingsFolder.appendingPathComponent(MeetingIndex.trashPrefix + UUID().uuidString)
      if rename(folder.path, trash.path) == 0 {
        try FileAccess.remove(trash)
      } else if errno != ENOENT {
        try FileAccess.remove(folder)
      }
    }
  }

  /// The folder for a meeting's audio, created when needed.
  func audioFolder(_ id: Meeting.ID) throws -> URL {
    let folder = layout.meetingFolder(entries[id]?.folder ?? id.uuidString)
      .appendingPathComponent("audio", isDirectory: true)
    try FileAccess.createFolder(folder)
    return folder
  }

  /// Brings `notes.md` up to date for meetings whose `meeting.json` another tool edited by
  /// hand. Problems are left for the next save to sort out.
  func refreshNotes(for ids: [Meeting.ID]) {
    for id in ids {
      try? lock.withLock {
        guard let meeting = try meeting(id).meeting, let entry = entries[id] else { return }
        try writeNotes(for: meeting, in: layout.meetingFolder(entry.folder))
      }
    }
  }

  /// Removes what an interrupted delete left behind.
  func removeLeftovers() {
    let folder = layout.meetingsFolder
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
    for name in names where name.hasPrefix(MeetingIndex.trashPrefix) {
      try? FileAccess.remove(folder.appendingPathComponent(name))
    }
  }

  private static let trashPrefix = ".trash-"

  // MARK: Inside

  private func writeNotes(for meeting: Meeting, in folder: URL) throws {
    let url = folder.appendingPathComponent(FolderLayout.meetingNotes)
    let notes = Data(meeting.markdown().utf8)
    if let current = try? FileAccess.read(url), current.data == notes { return }
    try FileAccess.writeAtomically(notes, to: url)
  }

  /// Every folder that holds a `meeting.json`, by meeting id. Folders whose name is not an
  /// id are somebody else's and are left alone.
  private func foldersOnDisk() -> [Meeting.ID: (folder: String, signature: FileSignature)] {
    var found: [Meeting.ID: (folder: String, signature: FileSignature)] = [:]
    guard let directory = opendir(layout.meetingsFolder.path) else { return found }
    defer { closedir(directory) }
    let descriptor = dirfd(directory)
    while let item = readdir(directory) {
      let length = Int(item.pointee.d_namlen)
      guard length == 36 else { continue }
      let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
          String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
        }
      }
      guard let id = UUID(uuidString: name) else { continue }
      var info = stat()
      guard fstatat(descriptor, name + "/" + FolderLayout.meetingFile, &info, 0) == 0 else { continue }
      // On a disk that tells upper and lower case apart, the usual spelling wins.
      if found[id] != nil, name != id.uuidString { continue }
      found[id] = (name, FileSignature(info))
    }
    return found
  }

  private func loadMissing() throws {
    try load(entries.filter { $0.value.loaded == nil }.map(\.key))
  }

  private enum Loaded {
    case meeting(Meeting, FileSignature)
    case missing
    case unreadable
  }

  /// Reads the given meetings, many at a time when there are many.
  private func load(_ ids: [Meeting.ID]) throws {
    guard !ids.isEmpty else { return }
    let files = ids.map { id in
      layout.meetingFolder(entries[id]?.folder ?? id.uuidString)
        .appendingPathComponent(FolderLayout.meetingFile)
    }
    var results = [Loaded](repeating: .missing, count: ids.count)
    results.withUnsafeMutableBufferPointer { buffer in
      // Each pass writes only its own slot, so the passes can run side by side.
      nonisolated(unsafe) let slots = buffer
      DispatchQueue.concurrentPerform(iterations: ids.count) { index in
        slots[index] = MeetingIndex.read(files[index], id: ids[index])
      }
    }
    for (index, id) in ids.enumerated() {
      switch results[index] {
      case .meeting(let meeting, let signature): entries[id]?.loaded = (signature, meeting)
      case .missing: entries[id] = nil
      case .unreadable: try recover(id, file: files[index])
      }
    }
    sorted = nil
  }

  private static func read(_ file: URL, id: Meeting.ID) -> Loaded {
    guard let (data, signature) = try? FileAccess.read(file) else {
      return FileSignature.of(file) == nil ? .missing : .unreadable
    }
    guard let meeting = decode(data, id: id) else { return .unreadable }
    return .meeting(meeting, signature)
  }

  /// The folder's name is the meeting's id, whatever the file says.
  private static func decode(_ data: Data, id: Meeting.ID) -> Meeting? {
    guard var meeting = try? LibraryJSON.decode(Meeting.self, from: data) else { return nil }
    meeting.id = id
    return meeting
  }

  /// A `meeting.json` would not load. Moves it aside and keeps what can still be read from
  /// it; when that is nothing, the meeting is left out.
  private func recover(_ id: Meeting.ID, file: URL) throws {
    try lock.withLock {
      switch try FileAccess.readSettled(file, decode: { MeetingIndex.decode($0, id: id) }) {
      case .missing:
        entries[id] = nil
      case .good(let meeting, let signature):
        entries[id]?.loaded = (signature, meeting)
      case .bad(let data):
        try FileAccess.setAside(file)
        guard var rescued = LibraryJSON.salvageObject(Meeting.self, from: data) else {
          entries[id] = nil
          return
        }
        rescued.id = id
        try save(rescued)
      }
    }
  }
}
