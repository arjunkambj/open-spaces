#if os(macOS)
  import AppKit
  import WisperUI

  // wisper-snapshots <output-dir> [--only <substring>] [--list]
  // Renders every snapshot case in WisperUI to PNG files, in light and dark.

  let usage = """
    Usage: wisper-snapshots <output-dir> [--only <substring>] [--list]

      <output-dir>        Folder for the PNG files. Created when missing.
      --only <substring>  Render only the cases whose name contains this text.
      --list              Print the case names and stop.
    """

  var outputPath: String?
  var only: String?
  var listOnly = false

  var arguments = CommandLine.arguments.dropFirst()
  while let argument = arguments.popFirst() {
    switch argument {
    case "--list":
      listOnly = true
    case "--only":
      guard let value = arguments.popFirst() else {
        FileHandle.standardError.write(Data("--only needs a value.\n\n\(usage)\n".utf8))
        exit(2)
      }
      only = value
    case "--help", "-h":
      print(usage)
      exit(0)
    default:
      guard !argument.hasPrefix("-"), outputPath == nil else {
        FileHandle.standardError.write(Data("Did not understand “\(argument)”.\n\n\(usage)\n".utf8))
        exit(2)
      }
      outputPath = argument
    }
  }

  // No Dock icon, no menu bar, and never the front app.
  NSApplication.shared.setActivationPolicy(.accessory)

  let cases = SnapshotRegistry.all.filter { snapshot in
    only.map { snapshot.name.localizedCaseInsensitiveContains($0) } ?? true
  }

  if listOnly {
    for snapshot in cases { print(snapshot.name) }
    exit(0)
  }

  guard let outputPath else {
    FileHandle.standardError.write(Data("\(usage)\n".utf8))
    exit(2)
  }
  guard !cases.isEmpty else {
    FileHandle.standardError.write(Data("No snapshot case matches.\n".utf8))
    exit(1)
  }

  do {
    let folder = URL(fileURLWithPath: outputPath, isDirectory: true)
    let files = try await SnapshotRenderer().render(cases, to: folder) { file in
      print(file.path)
    }
    print("Wrote \(files.count) images to \(folder.path)")
  } catch {
    FileHandle.standardError.write(Data("wisper-snapshots: \(error.localizedDescription)\n".utf8))
    exit(1)
  }
#else
  print("wisper-snapshots only runs on macOS.")
#endif
