#if os(macOS)
  import AppKit
  import WisperPhone
  import WisperUI

  // wisper-phone-snapshots <output-dir> [--only <substring>] [--list]
  // Draws the iPhone app's own screens and its keyboard to PNG files, in light and dark,
  // on a Mac. The screens shared with the Mac app are drawn by `wisper-snapshots` in packages/ui.

  let usage = """
    Usage: wisper-phone-snapshots <output-dir> [--only <substring>] [--list]

      <output-dir>        Folder for the PNG files. Created when missing.
      --only <substring>  Draw only the cases whose name contains this text.
      --list              Print the case names and stop.
    """

  func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
  }

  var outputPath: String?
  var only: String?
  var listOnly = false

  var arguments = CommandLine.arguments.dropFirst()
  while let argument = arguments.popFirst() {
    switch argument {
    case "--list":
      listOnly = true
    case "--only":
      guard let value = arguments.popFirst() else { fail("--only needs a value.\n\n\(usage)", code: 2) }
      only = value
    case "--help", "-h":
      print(usage)
      exit(0)
    default:
      guard !argument.hasPrefix("-"), outputPath == nil else {
        fail("Did not understand “\(argument)”.\n\n\(usage)", code: 2)
      }
      outputPath = argument
    }
  }

  // No Dock icon, no menu bar, and never the front app.
  NSApplication.shared.setActivationPolicy(.accessory)

  let cases = await PhoneSnapshots.cases().filter { snapshot in
    only.map { snapshot.name.localizedCaseInsensitiveContains($0) } ?? true
  }

  if listOnly {
    for snapshot in cases { print(snapshot.name) }
    exit(0)
  }
  guard let outputPath else { fail(usage, code: 2) }
  guard !cases.isEmpty else { fail("No snapshot case matches.", code: 1) }

  do {
    let folder = URL(fileURLWithPath: outputPath, isDirectory: true)
    let files = try await SnapshotRenderer().render(cases, to: folder) { file in
      print(file.path)
    }
    print("Wrote \(files.count) images to \(folder.path)")
  } catch {
    fail("wisper-phone-snapshots: \(error.localizedDescription)", code: 1)
  }
#else
  print("wisper-phone-snapshots only runs on macOS.")
#endif
