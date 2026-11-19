import Foundation
import WisperDomain

/// What reading a file came to, once it had stopped changing.
enum SettledRead<Value> {
  case missing
  case good(Value, FileSignature)
  /// The file is there, has stopped changing, and still cannot be understood.
  case bad(Data)
}

extension FileAccess {
  /// Reads a file that failed to load once more, with care: another tool may be in the
  /// middle of writing it without the lock. Tries again until it loads or stops changing.
  /// Call while holding the folder lock.
  static func readSettled<Value>(_ url: URL, decode: (Data) -> Value?) throws -> SettledRead<Value> {
    var previous: FileSignature?
    while true {
      guard let (data, signature) = try read(url) else { return .missing }
      if let value = decode(data) { return .good(value, signature) }
      if signature == previous, FileSignature.of(url) == signature { return .bad(data) }
      previous = signature
      usleep(40_000)
    }
  }
}

/// One JSON file in the data folder with a copy kept in memory.
///
/// The copy is trusted for as long as the file's signature stays the same, so a read costs
/// one `stat`. Not safe to share between threads: `FileLibrary` uses it from its own queue.
final class JSONDocument<Value: Codable & Equatable> {
  private let url: URL
  private let lock: FolderLock
  private let empty: Value
  private let salvage: (Data) -> Value?

  /// The file as `poll` last saw it. Outer `nil`: never looked. Inner `nil`: no file.
  private var observed: FileSignature??
  /// The content last read or written, and the signature of the file it came from.
  private var cached: (signature: FileSignature?, value: Value)?
  /// Goes up every time the content in memory is replaced.
  private(set) var revision = 0

  /// - Parameters:
  ///   - empty: what a missing file means.
  ///   - salvage: gets whatever can still be read out of a damaged file.
  init(url: URL, lock: FolderLock, empty: Value, salvage: @escaping (Data) -> Value?) {
    self.url = url
    self.lock = lock
    self.empty = empty
    self.salvage = salvage
  }

  /// The content on disk right now. `changed` is true when the file is not the one an
  /// earlier look saw, which means somebody else wrote it.
  func read() throws -> (value: Value, changed: Bool) {
    let (current, changed) = look()
    if let cached, cached.signature == current { return (cached.value, changed) }
    return (try load(), changed)
  }

  /// Looks at the file without reading it. True when it is not the one last seen.
  /// The first look only takes note of the file and answers false.
  @discardableResult
  func poll() -> Bool {
    look().changed
  }

  /// Takes `signature` as what the file looked like at an earlier moment, unless the file
  /// has been looked at already. The next look then reports what happened after that moment.
  func adopt(earlier signature: FileSignature?) {
    if case .none = observed { observed = .some(signature) }
  }

  /// Reads the newest content under the folder lock, changes it and writes it back, so a
  /// change made by another process in between is kept.
  @discardableResult
  func update(_ change: (inout Value) throws -> Void) throws -> Value {
    try lock.withLock {
      let before = try read().value
      var after = before
      try change(&after)
      if after != before { try write(after) }
      return after
    }
  }

  private func look() -> (current: FileSignature?, changed: Bool) {
    let current = FileSignature.of(url)
    defer { observed = .some(current) }
    if case .some(let known) = observed { return (current, known != current) }
    return (current, false)
  }

  private func write(_ newValue: Value) throws {
    let signature = try FileAccess.writeAtomically(try LibraryJSON.encode(newValue), to: url)
    observed = .some(signature)
    remember(newValue, signature)
  }

  private func load() throws -> Value {
    guard let (data, signature) = try FileAccess.read(url) else {
      return remember(empty, nil)
    }
    if let loaded = decode(data) { return remember(loaded, signature) }
    return try recover()
  }

  private func decode(_ data: Data) -> Value? {
    if LibraryJSON.isBlank(data) { return empty }
    return try? LibraryJSON.decode(Value.self, from: data)
  }

  /// The file would not load. Keeps the app going: the bad file is moved aside and what
  /// can still be read from it (or nothing) takes its place.
  private func recover() throws -> Value {
    try lock.withLock {
      switch try FileAccess.readSettled(url, decode: decode) {
      case .missing:
        return remember(empty, nil)
      case .good(let loaded, let signature):
        return remember(loaded, signature)
      case .bad(let data):
        try FileAccess.setAside(url)
        guard let rescued = salvage(data), rescued != empty else { return remember(empty, nil) }
        try write(rescued)
        return rescued
      }
    }
  }

  @discardableResult
  private func remember(_ newValue: Value, _ signature: FileSignature?) -> Value {
    cached = (signature, newValue)
    revision += 1
    return newValue
  }
}
