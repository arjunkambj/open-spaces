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
  ///   - environment: Where the data folder and this program are.
  public init(library: @autoclosure @escaping @Sendable () -> any Library, environment: Environment) {
    source = LazyLibrary(library)
    self.environment = environment
  }

  /// Runs one command line (without the program name) and returns the exit code:
  /// `0` for success, `1` when the command could not do what was asked, `2`
  /// when the command line itself was wrong.
  ///
  /// `["mcp"]` serves the Model Context Protocol on `io` until the input ends.
  @discardableResult
  public func run(_ arguments: [String], io: IO) async -> Int32 {
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

  /// Where things are: the data folder, and this program itself.
  public struct Environment: Sendable {
    /// The data folder.
    public var dataFolder: URL
    /// The value of `OPEN_WISPER_HOME` when the data folder was moved with it.
    public var homeOverride: String?
    /// Absolute path of this program, for `wisper mcp-config`.
    public var executablePath: String
    /// Relative paths given to the tool are resolved against this folder.
    public var workingDirectory: URL
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
