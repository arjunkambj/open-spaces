import Foundation
import Testing
import WisperDomain

@testable import WisperStore

/// A folder under the system's temporary folder that is removed when the test ends.
final class TemporaryFolder: Sendable {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-wisper-tests-\(UUID().uuidString)", isDirectory: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }

  func file(_ path: String) -> URL { url.appendingPathComponent(path) }

  func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: file(path).path) }

  func names(in path: String = "") -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: file(path).path)) ?? []).sorted()
  }

  /// Writes a file the way a careless outside tool would: straight into place, no lock.
  func writeFromOutside(_ text: String, to path: String) throws {
    let target = file(path)
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: target)
  }
}

/// The two adapters of the `Library` seam. The shared tests run against both.
enum Adapter: String, CaseIterable, CustomTestStringConvertible {
  case memory, files

  var testDescription: String { rawValue }

  func make() -> (library: any Library, folder: TemporaryFolder?) {
    switch self {
    case .memory:
      return (InMemoryLibrary(), nil)
    case .files:
      let folder = TemporaryFolder()
      return (FileLibrary(root: folder.url), folder)
    }
  }
}

/// Collects what a `changes()` stream reports, so a test can wait for a change.
final class ChangeRecorder: Sendable {
  private let seen = Locked<[LibraryChange]>([])
  private let task: Task<Void, Never>

  init(_ stream: AsyncStream<LibraryChange>) {
    let seen = seen
    task = Task {
      for await change in stream { seen.withLock { $0.append(change) } }
    }
  }

  deinit {
    task.cancel()
  }

  var all: [LibraryChange] { seen.withLock { $0 } }

  func count(of change: LibraryChange) -> Int { all.filter { $0 == change }.count }

  /// Waits until `change` has been reported at least `times` times. False when it never was.
  func saw(_ change: LibraryChange, times: Int = 1, within seconds: Double = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if count(of: change) >= times { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return count(of: change) >= times
  }

  /// Waits a while and says whether anything at all was reported.
  func stayedQuiet(for seconds: Double) async -> Bool {
    try? await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    return all.isEmpty
  }
}

/// Whole seconds ago, so the value is the same after a trip through any format.
func ago(_ seconds: TimeInterval, from now: Date = Date()) -> Date {
  Date(timeIntervalSince1970: (now.timeIntervalSince1970 - seconds).rounded(.down))
}
