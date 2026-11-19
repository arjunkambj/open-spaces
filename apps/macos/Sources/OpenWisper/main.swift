import AppKit
import WisperMacUI
import WisperUI

// Open Wisper for macOS. A menu bar app with one main window and a floating pill.
//
// AppKit runs the app (`NSApplicationDelegate`) and SwiftUI draws inside its windows:
// a menu bar item, a window that comes and goes and a panel that never takes focus
// are all things AppKit does directly and SwiftUI's `App` only does in part.

let launch = Launch(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)

switch launch.mode {
case .help:
  print(Launch.usage)
  exit(0)

case .mistake(let message):
  FileHandle.standardError.write(Data("\(message)\n\n\(Launch.usage)\n".utf8))
  exit(2)

case .snapshots(let folder, let only):
  // No Dock icon, no menu bar, and never the front app.
  NSApplication.shared.setActivationPolicy(.accessory)
  let cases = MacSnapshots.cases.filter { snapshot in
    only.map { snapshot.name.localizedCaseInsensitiveContains($0) } ?? true
  }
  guard !cases.isEmpty else {
    FileHandle.standardError.write(Data("No snapshot matches.\n".utf8))
    exit(1)
  }
  do {
    let files = try await SnapshotRenderer().render(
      cases,
      to: URL(fileURLWithPath: folder, isDirectory: true)
    ) {
      print($0.path)
    }
    print("Wrote \(files.count) images to \(folder)")
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("OpenWisper: \(error.localizedDescription)\n".utf8))
    exit(1)
  }

case .app:
  if OtherInstance.handOver() { exit(0) }
  run(AppDelegate(parts: Composition.real(), isDemo: false))

case .demo(let firstRun):
  run(AppDelegate(parts: Composition.demo(firstRun: firstRun), isDemo: true))
}

/// Runs the app until it quits. The app only holds its delegate weakly, so it is kept alive here.
@MainActor func run(_ delegate: AppDelegate) {
  let app = NSApplication.shared
  withExtendedLifetime(delegate) {
    app.delegate = delegate
    app.run()
  }
}
