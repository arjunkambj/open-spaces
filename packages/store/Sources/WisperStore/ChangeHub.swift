import Foundation
import WisperDomain

/// Hands every change to everyone who is listening. Each listener gets a stream of its own.
final class ChangeHub: Sendable {
  private struct State {
    var listeners: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]
    var finished = false
  }

  private let state = Locked(State())

  var isInUse: Bool { state.withLock { !$0.listeners.isEmpty } }

  /// A new stream. `onChange` is called when the stream starts and again when it ends.
  func stream(onChange: @escaping @Sendable () -> Void) -> AsyncStream<LibraryChange> {
    let (stream, continuation) = AsyncStream.makeStream(of: LibraryChange.self)
    let id = UUID()
    let open = state.withLock { state in
      if !state.finished { state.listeners[id] = continuation }
      return !state.finished
    }
    guard open else {
      continuation.finish()
      return stream
    }
    continuation.onTermination = { [weak self] _ in
      self?.state.withLock { _ = $0.listeners.removeValue(forKey: id) }
      onChange()
    }
    onChange()
    return stream
  }

  func send(_ change: LibraryChange) {
    let listeners = state.withLock { Array($0.listeners.values) }
    for listener in listeners { listener.yield(change) }
  }

  /// Ends every stream, now and from here on.
  func finish() {
    let listeners = state.withLock { state in
      defer { state.listeners.removeAll() }
      state.finished = true
      return Array(state.listeners.values)
    }
    for listener in listeners { listener.finish() }
  }
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}
