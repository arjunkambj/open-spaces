import Foundation
import SpacesDomain

// The outside world: this process's standard streams, and the running
// Spaces app.

extension SpacesAgent.Environment {
  /// The data folder and this program, as this process finds them.
  public static func live() -> SpacesAgent.Environment {
    let variables = ProcessInfo.processInfo.environment
    let home = variables[SpacesPaths.homeVariable].flatMap { $0.isEmpty ? nil : $0 }
    return SpacesAgent.Environment(
      dataFolder: SpacesPaths.defaultRoot(),
      homeOverride: home,
      // Not resolved through symbolic links: a link such as /usr/local/bin/spaces keeps
      // working after the app is updated, and the path it points at may not.
      executablePath: URL(
        fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "spaces"
      )
      .standardizedFileURL.path,
      workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    )
  }
}

extension SpacesAgent.IO {
  /// This process's standard input, output and error. Call it once.
  ///
  /// Anything other code prints to standard output afterwards is sent to
  /// standard error instead, so an MCP client only ever reads protocol
  /// messages there.
  public static func standard() -> SpacesAgent.IO {
    signal(SIGPIPE, SIG_IGN)
    let ownOutput = dup(STDOUT_FILENO)
    if ownOutput >= 0 { dup2(STDERR_FILENO, STDOUT_FILENO) }
    let output = LineWriter(descriptor: ownOutput >= 0 ? ownOutput : STDOUT_FILENO)
    let error = LineWriter(descriptor: STDERR_FILENO)
    let reader = LineReader(descriptor: STDIN_FILENO)
    return SpacesAgent.IO(
      // Nothing is read until someone asks for a line, so a command that does
      // not need input leaves it for whoever comes next in a shell script.
      input: AsyncStream(unfolding: { await reader.next() }),
      output: { output.write($0) },
      error: { error.write($0) }
    )
  }
}

/// Writes whole lines to a file descriptor, one at a time.
private final class LineWriter: @unchecked Sendable {
  private let lock = NSLock()
  private let descriptor: Int32

  init(descriptor: Int32) { self.descriptor = descriptor }

  func write(_ line: String) {
    let bytes = Array((line + "\n").utf8)
    lock.withLock {
      var sent = 0
      while sent < bytes.count {
        let count = bytes[sent...].withUnsafeBytes { Foundation.write(descriptor, $0.baseAddress, $0.count) }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return }
        sent += count
      }
    }
  }
}

/// Reads lines from a file descriptor. Only a line feed ends a line, so
/// unusual characters inside a JSON message never split it.
///
/// A line longer than `Limits.line` is never held in memory whole. Its start
/// is kept, a little longer than the limit so the reader of the line can see
/// that it is too long, the rest is thrown away as it arrives, and the last
/// `Limits.lineEnd` bytes are handed over after the start.
private final class LineReader: @unchecked Sendable {
  private let queue = DispatchQueue(label: "open-spaces.agent.input")
  private let descriptor: Int32
  private var buffer: [UInt8] = []
  /// How much of `buffer` is known to hold no line feed, so no byte is looked at twice.
  private var searched = 0
  /// The start of a line that is too long, while the rest of it is being read and dropped.
  private var start: [UInt8]?
  /// The last bytes read of that line so far.
  private var tail: [UInt8] = []
  private var ended = false

  init(descriptor: Int32) { self.descriptor = descriptor }

  func next() async -> String? {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: self.readLine()) }
    }
  }

  /// A line that was too long: its start, then its end.
  private func tooLong(_ start: [UInt8], last: [UInt8]) -> String {
    var end = Array((tail + last).suffix(Limits.lineEnd))
    tail = []
    if end.last == 0x0D { end.removeLast() }
    return String(decoding: start + end, as: UTF8.self)
  }

  private func readLine() -> String? {
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
      if let newline = buffer[searched...].firstIndex(of: 0x0A) {
        var line = Array(buffer[..<newline])
        buffer.removeSubrange(...newline)
        searched = 0
        if let start {
          self.start = nil
          return tooLong(start, last: line)
        }
        if line.last == 0x0D { line.removeLast() }
        return String(decoding: line, as: UTF8.self)
      }
      searched = buffer.count
      if start != nil {
        tail = Array((tail + buffer.suffix(Limits.lineEnd)).suffix(Limits.lineEnd))
        buffer.removeAll(keepingCapacity: true)
        searched = 0
      } else if buffer.count > Limits.line {
        start = buffer
        buffer.removeAll()
        searched = 0
      }
      if ended {
        if let start {
          self.start = nil
          return tooLong(start, last: [])
        }
        guard !buffer.isEmpty else { return nil }
        defer { buffer = [] }
        searched = 0
        return String(decoding: buffer, as: UTF8.self)
      }
      let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count > 0 {
        buffer.append(contentsOf: chunk[..<count])
      } else if !(count < 0 && errno == EINTR) {
        ended = true
      }
    }
  }
}

enum Live {
  #if os(macOS)
    /// Runs a program and returns its exit code and, when asked, what it printed.
    /// The program never shares this process's standard output.
    private static func launch(
      _ path: String,
      _ arguments: [String],
      capture: Bool = false
    ) async throws -> (code: Int32, output: String) {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
          let process = Process()
          process.executableURL = URL(fileURLWithPath: path)
          process.arguments = arguments
          let pipe = capture ? Pipe() : nil
          process.standardOutput = pipe ?? FileHandle.nullDevice
          process.standardError = FileHandle.nullDevice
          process.standardInput = FileHandle.nullDevice
          do {
            try process.run()
          } catch {
            continuation.resume(throwing: error)
            return
          }
          // Read before waiting: a program with a lot to say stops until someone reads it.
          let data = pipe.flatMap { try? $0.fileHandleForReading.readToEnd() } ?? Data()
          process.waitUntilExit()
          continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
        }
      }
    }

    /// Hands a link to the Spaces app without bringing it to the front.
    static func open(_ url: URL) async throws {
      let result = try await launch("/usr/bin/open", ["-g", url.absoluteString])
      guard result.code == 0 else {
        throw AgentError.failed(
          "macOS found no app that opens \(SpacesLink.scheme):// links. Is Spaces installed? Open the "
            + "app once, then try again."
        )
      }
    }

    /// Looks for the app among the running programs. The app is the program
    /// inside `Spaces.app` that is not this tool. `nil` when that cannot be told.
    static func appIsRunning() async -> Bool? {
      guard let result = try? await launch("/bin/ps", ["-axo", "comm="], capture: true), result.code == 0
      else { return nil }
      return result.output.split(separator: "\n").contains { line in
        let name = line.split(separator: "/").last.map(String.init) ?? ""
        if name == "spaces" { return false }
        return line.contains("/Spaces.app/Contents/MacOS/") || name == "Spaces"
          || name == "Spaces"
      }
    }
  #else
    static func open(_ url: URL) async throws {
      throw AgentError.failed("Recording can only be started and stopped from a Mac.")
    }

    static func appIsRunning() async -> Bool? { nil }
  #endif
}
