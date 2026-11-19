import Foundation
import WisperDomain

/// `Library` backed by plain files in one folder.
///
/// Everything is JSON, Markdown or audio that a person or another tool can read; the layout
/// is described in `docs/data-format.md`. Any number of processes may use the same folder at
/// once (the app and the `wisper` tool): each write replaces a file in one step and is made
/// under a lock shared between processes, and `changes()` reports what the others wrote.
///
/// Make one per process and share it.
public actor FileLibrary: Library {
  // File work blocks, so it gets a queue of its own instead of the shared pool.
  private let queue: DispatchSerialQueue
  private let layout: FolderLayout
  private let watchMode: WatchMode
  private let hub = ChangeHub()
  private let lock: FolderLock
  private let settingsFile: JSONDocument<Settings>
  private let wordsFile: JSONDocument<[DictionaryWord]>
  private let snippetsFile: JSONDocument<[Snippet]>
  private let dictationsFile: JSONDocument<[Dictation]>
  private let meetingIndex: MeetingIndex
  private var watcher: FolderWatcher?
  private var tidied = false
  /// The history newest first, and the revision of `dictationsFile` it was made from.
  private var sortedDictations: (revision: Int, value: [Dictation])?

  /// Runs this library's work on its own queue.
  public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

  /// Opens the library in `root`. Nothing is read or created until it is needed, so this
  /// never fails and is cheap to call.
  public init(root: URL = WisperPaths.defaultRoot()) {
    self.init(root: root, watching: .automatic)
  }

  init(root: URL, watching watchMode: WatchMode) {
    let layout = FolderLayout(root: root.standardizedFileURL)
    let lock = FolderLock(layout: layout)
    self.queue = DispatchSerialQueue(label: "dev.openwisper.store.library", qos: .userInitiated)
    self.layout = layout
    self.watchMode = watchMode
    self.lock = lock
    settingsFile = JSONDocument(
      url: layout.file(FolderLayout.settings),
      lock: lock,
      empty: Settings(),
      salvage: { LibraryJSON.salvageObject(Settings.self, from: $0) }
    )
    wordsFile = JSONDocument(
      url: layout.file(FolderLayout.words),
      lock: lock,
      empty: [],
      salvage: { LibraryJSON.salvageArray(DictionaryWord.self, from: $0) }
    )
    snippetsFile = JSONDocument(
      url: layout.file(FolderLayout.snippets),
      lock: lock,
      empty: [],
      salvage: { LibraryJSON.salvageArray(Snippet.self, from: $0) }
    )
    dictationsFile = JSONDocument(
      url: layout.file(FolderLayout.dictations),
      lock: lock,
      empty: [],
      salvage: { LibraryJSON.salvageArray(Dictation.self, from: $0) }
    )
    meetingIndex = MeetingIndex(layout: layout, lock: lock)
  }

  deinit {
    watcher?.stop()
    hub.finish()
  }

  // MARK: Settings

  public func settings() throws -> Settings {
    try read(settingsFile, .settings)
  }

  @discardableResult
  public func updateSettings(_ change: @Sendable (inout Settings) -> Void) throws -> Settings {
    try write(.settings) { try settingsFile.update { change(&$0) } }
  }

  // MARK: Dictionary

  public func words() throws -> [DictionaryWord] {
    try read(wordsFile, .words).sorted { $0.createdAt > $1.createdAt }
  }

  public func save(_ word: DictionaryWord) throws {
    try write(.words) {
      try wordsFile.update { words in
        words.removeAll { $0.id == word.id }
        words.append(word)
      }
    }
  }

  public func deleteWord(_ id: DictionaryWord.ID) throws {
    try write(.words) { try wordsFile.update { words in words.removeAll { $0.id == id } } }
  }

  // MARK: Snippets

  public func snippets() throws -> [Snippet] {
    try read(snippetsFile, .snippets).sorted { $0.createdAt > $1.createdAt }
  }

  public func save(_ snippet: Snippet) throws {
    try write(.snippets) {
      try snippetsFile.update { snippets in
        snippets.removeAll { $0.id == snippet.id }
        snippets.append(snippet)
      }
    }
  }

  public func deleteSnippet(_ id: Snippet.ID) throws {
    try write(.snippets) { try snippetsFile.update { snippets in snippets.removeAll { $0.id == id } } }
  }

  // MARK: Dictations

  public func dictations(search: String?, limit: Int?) throws -> [Dictation] {
    let stored = try read(dictationsFile, .dictations)
    var result: [Dictation]
    if let sortedDictations, sortedDictations.revision == dictationsFile.revision {
      result = sortedDictations.value
    } else {
      result = stored.sorted { $0.createdAt > $1.createdAt }
      sortedDictations = (dictationsFile.revision, result)
    }
    if let search, !search.isEmpty {
      result = result.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }
    if let limit { result = Array(result.prefix(max(0, limit))) }
    return result
  }

  public func save(_ dictation: Dictation) throws {
    try write(.dictations) {
      let retention = try read(settingsFile, .settings).historyRetention
      var orphans: Set<String> = []
      try dictationsFile.update { history in
        var audio = Set(history.compactMap(\.audioFile))
        if let file = dictation.audioFile { audio.insert(file) }
        history.removeAll { $0.id == dictation.id }
        history.append(dictation)
        if let maxAge = retention.maxAge {
          let cutoff = Date().addingTimeInterval(-maxAge)
          history.removeAll { $0.createdAt < cutoff || maxAge == 0 }
        }
        orphans = audio.subtracting(history.compactMap(\.audioFile))
      }
      // The entries are already gone, so a file that will not go is not worth failing for.
      _ = removeDictationAudio(orphans)
    }
  }

  public func deleteDictations(_ ids: Set<Dictation.ID>) throws {
    try write(.dictations) {
      var orphans: Set<String> = []
      try dictationsFile.update { history in
        let audio = Set(history.compactMap(\.audioFile))
        history.removeAll { ids.contains($0.id) }
        orphans = audio.subtracting(history.compactMap(\.audioFile))
      }
      try requireRemoved(removeDictationAudio(orphans))
    }
  }

  public func deleteAllDictations() throws {
    try write(.dictations) {
      var doomed: Set<String> = []
      try dictationsFile.update { history in
        doomed = Set(history.compactMap(\.audioFile))
        history = []
      }
      // Recordings that never made it into the history (a crash, a quit) go as well. One
      // that is being made right now is left alone.
      let cutoff = Date().addingTimeInterval(-FileLibrary.recordingGrace)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.dictationAudio.path)) ?? []
      for name in names where !doomed.contains(name) {
        let url = layout.dictationAudio.appendingPathComponent(name)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate
        if let modified, modified < cutoff { doomed.insert(name) }
      }
      try requireRemoved(removeDictationAudio(doomed))
    }
  }

  public func dictationAudioDirectory() throws -> URL {
    try FileAccess.createFolder(layout.dictationAudio)
    return layout.dictationAudio
  }

  // MARK: Meetings

  public func meetings(search: String?) throws -> [Meeting] {
    noteMeetingScan(meetingIndex.scan())
    let all = try meetingIndex.all()
    guard let search, !search.isEmpty else { return all }
    return all.filter { meeting in
      let haystack =
        [meeting.title, meeting.userNotes, meeting.notes?.summary ?? ""]
        + meeting.tags + meeting.segments.map(\.text)
        + (meeting.notes?.keyPoints ?? []) + (meeting.notes?.decisions ?? [])
        + (meeting.notes?.actionItems.map(\.text) ?? [])
      return haystack.contains { $0.localizedCaseInsensitiveContains(search) }
    }
  }

  public func meeting(_ id: Meeting.ID) throws -> Meeting? {
    let (meeting, changed) = try meetingIndex.meeting(id)
    if changed {
      hub.send(.meetings)
      meetingIndex.refreshNotes(for: [id])
    }
    return meeting
  }

  public func save(_ meeting: Meeting) throws {
    try write(.meetings) { try meetingIndex.save(meeting) }
  }

  public func deleteMeeting(_ id: Meeting.ID) throws {
    try write(.meetings) { try meetingIndex.delete(id) }
  }

  public func audioDirectory(forMeeting id: Meeting.ID) throws -> URL {
    try meetingIndex.audioFolder(id)
  }

  // MARK: Changes

  public nonisolated func changes() -> AsyncStream<LibraryChange> {
    // What the folder looks like right now, so a write that lands before the watch is up
    // is still reported.
    let files = [FolderLayout.settings, FolderLayout.words, FolderLayout.snippets, FolderLayout.dictations]
    let baseline = Baseline(moment: Date(), files: files.map { FileSignature.of(layout.file($0)) })
    return hub.stream { [weak self] in
      guard let self else { return }
      Task { await self.listenersChanged(baseline) }
    }
  }

  /// The state of the folder at the moment somebody started to listen.
  private struct Baseline: Sendable {
    var moment: Date
    /// Settings, words, snippets, dictations.
    var files: [FileSignature?]
  }

  /// Watches the folder for as long as somebody is listening, and not a moment longer.
  private func listenersChanged(_ baseline: Baseline) {
    guard hub.isInUse else {
      watcher?.stop()
      watcher = nil
      return
    }
    guard watcher == nil else { return }
    let watcher = FolderWatcher(layout: layout) { [weak self] in
      guard let self else { return }
      Task { await self.lookForChanges() }
    }
    watcher.start(watchMode)
    self.watcher = watcher
    // Files that were read before are compared with what was read. The rest are compared
    // with what they were when the listener arrived. Nothing slips through in between.
    settingsFile.adopt(earlier: baseline.files[0])
    wordsFile.adopt(earlier: baseline.files[1])
    snippetsFile.adopt(earlier: baseline.files[2])
    dictationsFile.adopt(earlier: baseline.files[3])
    lookForChanges(since: baseline.moment)
  }

  /// Compares the folder with what was last seen and reports the differences.
  private func lookForChanges(since moment: Date? = nil) {
    if settingsFile.poll() { hub.send(.settings) }
    if wordsFile.poll() { hub.send(.words) }
    if snippetsFile.poll() { hub.send(.snippets) }
    if dictationsFile.poll() { hub.send(.dictations) }
    noteMeetingScan(meetingIndex.scan(since: moment))
  }

  private func noteMeetingScan(_ scan: (changed: Bool, edited: [Meeting.ID])) {
    if scan.changed { hub.send(.meetings) }
    meetingIndex.refreshNotes(for: scan.edited)
  }

  // MARK: Inside

  /// Unreferenced audio newer than this many seconds may be a recording in progress.
  private static let recordingGrace: TimeInterval = 600

  /// Reads a file's content. If another process changed the file since it was last looked
  /// at, listeners hear about it now instead of when the watcher gets round to it.
  private func read<Value>(_ file: JSONDocument<Value>, _ kind: LibraryChange) throws -> Value {
    let (value, changed) = try file.read()
    if changed { hub.send(kind) }
    return value
  }

  /// Runs a change under the lock shared with other processes, then tells the listeners.
  @discardableResult
  private func write<Result>(_ kind: LibraryChange, _ body: () throws -> Result) throws -> Result {
    let result = try lock.withLock {
      if !tidied {
        tidied = true
        FileAccess.removeStaleTemporaryFiles(in: layout.root)
        meetingIndex.removeLeftovers()
      }
      return try body()
    }
    hub.send(kind)
    return result
  }

  /// Deletes kept audio by file name. Returns the names that could not be deleted.
  private func removeDictationAudio(_ names: Set<String>) -> [String] {
    names.sorted().filter { name in
      // A name is only ever a file inside the audio folder, never a path out of it.
      guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return false }
      return (try? FileAccess.remove(layout.dictationAudio.appendingPathComponent(name))) == nil
    }
  }

  private func requireRemoved(_ failed: [String]) throws {
    guard !failed.isEmpty else { return }
    throw WisperError.storage(
      failed.count == 1
        ? "The history entry is gone, but its audio file \(failed[0]) could not be deleted."
        : "The history entries are gone, but \(failed.count) of their audio files could not be deleted."
    )
  }
}
