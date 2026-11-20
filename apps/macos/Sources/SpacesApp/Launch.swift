import Foundation

/// How this run of the app was asked to start, read from its arguments.
struct Launch {
  enum Mode {
    /// The real app.
    case app
    /// The whole app on made-up data: no microphone, saved key, shortcuts, network or sounds.
    /// `firstRun` starts it before setup, to see the first-run steps.
    case demo(firstRun: Bool)
    /// Draw the still pictures into a folder and quit.
    case snapshots(folder: String, only: String?)
    case help
    case mistake(String)
  }

  var mode: Mode

  static let usage = """
    Spaces

      Spaces                              Start the app.
      Spaces --demo                       Start on made-up data. Nothing real is touched.
      Spaces --demo --first-run           The same, starting at first-run setup.
      Spaces --snapshots <folder> [--only <text>]
                                              Draw the app's screens as PNG files and quit.

    Environment:
      SPACES_HOME      Folder for the app's data, instead of Application Support/Spaces.
    """

  init(arguments: [String]) {
    var mode = Mode.app
    var rest = arguments.dropFirst()
    while let argument = rest.popFirst() {
      switch argument {
      case "--demo":
        if case .app = mode { mode = .demo(firstRun: false) }
      case "--first-run":
        // Only the demo can be put back to before setup.
        guard case .demo = mode else {
          self.mode = .mistake("--first-run goes after --demo.")
          return
        }
        mode = .demo(firstRun: true)
      case "--snapshots":
        guard let folder = rest.popFirst(), !folder.hasPrefix("-") else {
          self.mode = .mistake("--snapshots needs a folder.")
          return
        }
        mode = .snapshots(folder: folder, only: nil)
      case "--only":
        guard case .snapshots(let folder, _) = mode, let text = rest.popFirst() else {
          self.mode = .mistake("--only needs a value and goes after --snapshots <folder>.")
          return
        }
        mode = .snapshots(folder: folder, only: text)
      case "--help", "-h":
        self.mode = .help
        return
      default:
        // macOS adds arguments of its own when it opens an app (-NSDocumentRevisionsDebugMode, -psn_...).
        continue
      }
    }
    self.mode = mode
  }
}
