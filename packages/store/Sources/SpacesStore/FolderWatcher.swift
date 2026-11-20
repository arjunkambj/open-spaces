import Foundation
import SpacesDomain

#if os(macOS)
  import CoreServices
#endif

/// Says when something in the data folder may have changed. It does not say what: the
/// library looks for itself, which is cheap. Bursts of activity arrive as one call.
///
/// On macOS it listens to file system events. iOS has none of those for a folder tree, so
/// there it watches the top folder and the meetings folder for files being added, replaced
/// or removed, and also looks at everything once every `pollInterval` seconds, which catches
/// what those two watches cannot see.
final class FolderWatcher: @unchecked Sendable {
  private let layout: FolderLayout
  private let onActivity: @Sendable () -> Void
  /// Guards everything below.
  private let queue = DispatchQueue(label: "dev.openspaces.store.watcher", qos: .utility)
  private var running = false
  private var timer: (any DispatchSourceTimer)?
  private var folderSources: [String: any DispatchSourceFileSystemObject] = [:]
  private var debouncing = false
  #if os(macOS)
    private var stream: FSEventStreamRef?
  #endif

  /// Bursts closer together than this arrive as one call.
  private static let quietTime: TimeInterval = 0.08
  /// How often everything is looked at, where there are no file system events.
  private static let pollInterval: TimeInterval = 2

  /// `onActivity` is called on a private queue.
  init(layout: FolderLayout, onActivity: @escaping @Sendable () -> Void) {
    self.layout = layout
    self.onActivity = onActivity
  }

  deinit {
    stopOnQueue()
  }

  func start() {
    queue.async { [self] in
      guard !running else { return }
      running = true
      // Watching needs something to watch. Reading alone never makes the folder.
      try? FileAccess.createFolder(layout.root)
      #if os(macOS)
        if !startEventStream() { startPolling() }
      #else
        startPolling()
      #endif
      lookAfterStarting()
    }
  }

  /// Whatever was written while the watch was being set up is not announced by it. One
  /// look now, and one a moment later for a watch that was slow to come up, covers that.
  private func lookAfterStarting() {
    onActivity()
    queue.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, self.running else { return }
      self.onActivity()
    }
  }

  func stop() {
    queue.async { [self] in stopOnQueue() }
  }

  private func stopOnQueue() {
    running = false
    timer?.cancel()
    timer = nil
    for source in folderSources.values { source.cancel() }
    folderSources.removeAll()
    #if os(macOS)
      if let stream {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
      }
      stream = nil
    #endif
  }

  // MARK: Polling

  private func startPolling() {
    let interval = FolderWatcher.pollInterval
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + interval,
      repeating: interval,
      leeway: .milliseconds(Int(interval * 250))
    )
    timer.setEventHandler { [weak self] in
      guard let self, self.running else { return }
      self.watchFolders()
      self.onActivity()
    }
    timer.resume()
    self.timer = timer
    watchFolders()
  }

  /// Watches the two folders whose own contents change when a file is replaced in one step.
  /// A folder that is not there yet, or was replaced, is picked up on a later pass.
  private func watchFolders() {
    for folder in [layout.root, layout.meetingsFolder] where folderSources[folder.path] == nil {
      let path = folder.path
      let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .delete, .rename, .revoke],
        queue: queue
      )
      source.setEventHandler { [weak self, weak source] in
        guard let self, let source, self.running else { return }
        if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
          source.cancel()
          self.folderSources[path] = nil
        }
        self.activitySoon()
      }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      folderSources[path] = source
    }
  }

  private func activitySoon() {
    guard !debouncing else { return }
    debouncing = true
    queue.asyncAfter(deadline: .now() + FolderWatcher.quietTime) { [weak self] in
      guard let self else { return }
      self.debouncing = false
      if self.running { self.onActivity() }
    }
  }

  // MARK: File system events

  #if os(macOS)
    private func startEventStream() -> Bool {
      // The events name real paths, so ask for the real path of the folder.
      guard let resolved = realpath(layout.root.path, nil) else { return false }
      defer { free(resolved) }
      let root = String(cString: resolved)

      // The stream keeps the relay alive, and the relay does not keep the watcher alive,
      // so an event that arrives late finds nobody instead of a dead object.
      let relay = Relay(self)
      var context = FSEventStreamContext(
        version: 0,
        info: Unmanaged.passUnretained(relay).toOpaque(),
        retain: { info in
          guard let info else { return nil }
          _ = Unmanaged<Relay>.fromOpaque(info).retain()
          return info
        },
        release: { info in
          guard let info else { return }
          Unmanaged<Relay>.fromOpaque(info).release()
        },
        copyDescription: nil
      )
      let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info, let watcher = Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue().watcher
        else { return }
        let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        for index in 0..<count where watcher.matters(String(cString: names[index]), flags: flags[index]) {
          watcher.onActivity()
          return
        }
      }
      // Creating the stream is what takes hold of the relay, so it must live until then.
      let created = withExtendedLifetime(relay) {
        FSEventStreamCreate(
          nil,
          callback,
          &context,
          [root] as CFArray,
          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
          FolderWatcher.quietTime,
          // "Watch root" also reports the folder itself being moved or deleted.
          FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        )
      }
      guard let stream = created else { return false }
      FSEventStreamSetDispatchQueue(stream, queue)
      guard FSEventStreamStart(stream) else {
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        return false
      }
      self.stream = stream
      return true
    }

    private final class Relay {
      weak var watcher: FolderWatcher?

      init(_ watcher: FolderWatcher) {
        self.watcher = watcher
      }
    }

    /// Audio being recorded makes a steady flow of events that never changes what the
    /// library holds. Everything else matters.
    private func matters(_ path: String, flags: FSEventStreamEventFlags) -> Bool {
      let coarse = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
      if flags & FSEventStreamEventFlags(coarse) != 0 { return true }
      let parts = path.split(separator: "/")
      guard let last = parts.last else { return true }
      if last == layout.dictationAudio.lastPathComponent { return false }
      if last == "audio", parts.count >= 3, parts[parts.count - 3] == FolderLayout.meetings { return false }
      return true
    }
  #endif
}
