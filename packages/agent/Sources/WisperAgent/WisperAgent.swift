import Foundation
import WisperDomain

/// The `wisper` tool: everything an agent (or a person in a terminal) can do
/// with the Open Wisper library.
///
/// One catalogue of tools sits behind two front ends: shell commands
/// (`wisper meetings list`) and a Model Context Protocol server
/// (`wisper mcp`). Both are driven through `run`.
///
/// It reads and writes the library only. It has no access to the Keychain, so
/// it can never see the API key.
public struct WisperAgent: Sendable {
  /// The version reported by `wisper --version` and to MCP clients.
  public static let version = "0.1.0"

  private let source: LazyLibrary
  private let environment: Environment

  /// - Parameters:
  ///   - library: Where the data lives. It is only created when a command needs it,
  ///     so `wisper --help` never touches the disk.
  ///   - environment: The outside world. Tests pass their own.
  public init(
    library: @autoclosure @escaping @Sendable () -> any Library,
    environment: Environment = .live()
  ) {
    source = LazyLibrary(library)
    self.environment = environment
  }

  /// Runs one command line (without the program name) and returns the exit code:
  /// `0` for success, `1` when the command could not do what was asked, `2`
  /// when the command line itself was wrong.
  ///
  /// `["mcp"]` serves the Model Context Protocol on `io` until the input ends.
  @discardableResult
  public func run(_ arguments: [String], io: IO = .standard()) async -> Int32 {
    await CommandLineFrontEnd(source: source, environment: environment, io: io).run(arguments)
  }

  /// How the tool talks: lines in, lines out.
  public struct IO: Sendable {
    /// Lines read from the caller, without their line endings. Only `wisper mcp` reads them.
    public var input: AsyncStream<String>
    /// Writes one piece of output and ends the line.
    public var output: @Sendable (String) -> Void
    /// Writes one line of errors or logs.
    public var error: @Sendable (String) -> Void

    public init(
      input: AsyncStream<String>,
      output: @escaping @Sendable (String) -> Void,
      error: @escaping @Sendable (String) -> Void
    ) {
      self.input = input
      self.output = output
      self.error = error
    }
  }

  /// The world outside the library: the clock, the running app, this program's own location.
  public struct Environment: Sendable {
    public var now: @Sendable () -> Date
    /// Dates are written with this zone's offset.
    public var timeZone: TimeZone
    /// The data folder, for `wisper doctor`.
    public var dataFolder: URL
    /// The value of `OPEN_WISPER_HOME` when the data folder was moved with it.
    public var homeOverride: String?
    /// Absolute path of this program, for `wisper mcp-config`.
    public var executablePath: String
    /// Relative paths given to the tool are resolved against this folder.
    public var workingDirectory: URL
    /// Hands a `WisperLink` URL to the Open Wisper app. Throws when that is not possible.
    public var openLink: @Sendable (URL) async throws -> Void
    /// Whether the app seems to be running. `nil` when that cannot be told.
    public var appIsRunning: @Sendable () async -> Bool?
    /// How long to wait for the app to act on a link before giving up.
    public var appWait: Duration

    public init(
      now: @escaping @Sendable () -> Date = { Date() },
      timeZone: TimeZone = .current,
      dataFolder: URL,
      homeOverride: String? = nil,
      executablePath: String,
      workingDirectory: URL,
      openLink: @escaping @Sendable (URL) async throws -> Void,
      appIsRunning: @escaping @Sendable () async -> Bool?,
      appWait: Duration = .seconds(8)
    ) {
      self.now = now
      self.timeZone = timeZone
      self.dataFolder = dataFolder
      self.homeOverride = homeOverride
      self.executablePath = executablePath
      self.workingDirectory = workingDirectory
      self.openLink = openLink
      self.appIsRunning = appIsRunning
      self.appWait = appWait
    }
  }
}

/// Creates the library the first time it is asked for.
final class LazyLibrary: @unchecked Sendable {
  private let lock = NSLock()
  private let make: @Sendable () -> any Library
  private var made: (any Library)?

  init(_ make: @escaping @Sendable () -> any Library) { self.make = make }

  var library: any Library {
    lock.withLock {
      if let made { return made }
      let fresh = make()
      made = fresh
      return fresh
    }
  }
}
