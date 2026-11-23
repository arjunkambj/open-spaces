import Foundation
import SpacesDomain

/// The `agents` folder: one `<pid>.json` per `spaces mcp` server, written by that server.
///
/// Reading it tidies it: a server that is gone without saying so is read as stopped, and the
/// files of servers that stopped more than `AgentSession.keptFor` ago are deleted.
struct AgentFolder: Sendable {
  let layout: FolderLayout

  func save(_ session: AgentSession) throws {
    try FileAccess.createFolder(layout.agentsFolder)
    try FileAccess.writeAtomically(LibraryJSON.encode(session), to: file(session.pid))
  }

  /// Every session worth showing, most recently used first.
  func sessions(now: Date = Date()) -> [AgentSession] {
    let cutoff = now.addingTimeInterval(-AgentSession.keptFor)
    var found: [AgentSession] = []
    for (pid, url) in files() {
      guard let data = (try? FileAccess.read(url))?.data,
        var session = try? LibraryJSON.decode(AgentSession.self, from: data), session.pid == pid
      else {
        // Not one of ours, or not readable: left alone, unless it is old.
        if let signature = FileSignature.of(url),
          Double(signature.modifiedSeconds) < cutoff.timeIntervalSince1970
        {
          try? FileAccess.remove(url)
        }
        continue
      }
      if session.isConnected, !Self.isRunning(pid, startedBy: session.startedAt) {
        session.endedAt = session.lastActiveAt
      }
      if let ended = session.endedAt, ended < cutoff {
        try? FileAccess.remove(url)
        continue
      }
      found.append(session)
    }
    return found.sorted { $0.lastActiveAt > $1.lastActiveAt }
  }

  /// What the folder holds right now, to tell whether it changed.
  func signature() -> [Int32: FileSignature] {
    var signatures: [Int32: FileSignature] = [:]
    for (pid, url) in files() { signatures[pid] = FileSignature.of(url) }
    return signatures
  }

  private func file(_ pid: Int32) -> URL {
    layout.agentsFolder.appendingPathComponent("\(pid).json")
  }

  /// The session files by process ID. Writes in progress and anything else are left out.
  private func files() -> [(Int32, URL)] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.agentsFolder.path)) ?? []
    return names.compactMap { name in
      guard name.hasSuffix(".json"), let pid = Int32(name.dropLast(5)), pid > 0 else { return nil }
      return (pid, file(pid))
    }
  }

  /// Whether the process that wrote a session still runs. A process number can be given to
  /// another program once the first one is gone, so on a Mac a process that started after the
  /// session did is not the server.
  private static func isRunning(_ pid: Int32, startedBy date: Date) -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
    let start = info.kp_proc.p_un.__p_starttime
    let started = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    // The server notes its start a moment after the process began; clocks are not exact.
    return started <= date.addingTimeInterval(5)
  }
}
