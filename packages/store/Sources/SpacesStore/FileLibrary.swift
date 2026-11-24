import Foundation
import SpacesDomain

/// `Library` backed by plain files in one folder.
///
/// Everything is JSON, Markdown or audio that a person or another tool can read; the layout
/// is described in `docs/data-format.md`. Any number of processes may use the same folder at
/// once (the app and the `spaces` tool): each write replaces a file in one step and is made
/// under a lock shared between processes, and `changes()` reports what the others wrote.
///
/// Make one per process and share it.
public actor FileLibrary: Library {
  // File work blocks, so it gets a queue of its own instead of the shared pool.
  private let queue: DispatchSerialQueue
  private let layout: FolderLayout
  private let hub = ChangeHub()
  private let lock: FolderLock
  private let settingsFile: JSONDocument<Settings>
  private let wordsFile: JSONDocument<[DictionaryWord]>
  private let snippetsFile: JSONDocument<[Snippet]>
  private let dictationsFile: JSONDocument<[Dictation]>
  private let tasksFile: JSONDocument<TaskList>
  private let meetingIndex: MeetingIndex
  private let agentFolder: AgentFolder
  /// What the agents folder held when it was last looked at, once somebody listens.
  private var agentsSeen: [Int32: FileSignature]?
  private var watcher: FolderWatcher?
  private var tidied = false
  /// The history newest first, and the revision of `dictationsFile` it was made from.
  private var sortedDictations: (revision: Int, value: [Dictation])?

  /// Runs this library's work on its own queue.
  public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

  /// Opens the library in `root`. Nothing is read or created until it is needed, so this
  /// never fails and is cheap to call.
  public init(root: URL = SpacesPaths.defaultRoot()) {
    let layout = FolderLayout(root: root.standardizedFileURL)
    let lock = FolderLock(layout: layout)
    self.queue = DispatchSerialQueue(label: "dev.openspaces.store.library", qos: .userInitiated)
    self.layout = layout
    self.lock = lock
    // A data folder made by something else (or opened up later) is closed to other users
    // again every time it is opened. A folder that is not there yet is made private later.
    FileAccess.makePrivate(layout.root)
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
    tasksFile = JSONDocument(
      url: layout.file(FolderLayout.tasks),
      lock: lock,
      empty: TaskList(),
      salvage: { LibraryJSON.salvageObject(TaskList.self, from: $0) }
    )
    meetingIndex = MeetingIndex(layout: layout, lock: lock)
    agentFolder = AgentFolder(layout: layout)
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

  @discardableResult
  public func updateMeeting(
    _ id: Meeting.ID,
    _ change: @Sendable (inout Meeting) -> Void
  ) throws -> Meeting? {
    // Read and write under one hold of the shared lock, so neither this process nor
    // another one can change the meeting in between.
    let (result, saved, editedOutside): (Meeting?, Bool, Bool) = try lock.withLock {
      // `outside` is true when somebody else changed the file since this library last looked.
      let (found, outside) = try meetingIndex.meeting(id)
      guard let stored = found else { return (nil, false, outside) }
      var meeting = stored
      change(&meeting)
      // The folder name decides the ID; a change cannot move the meeting.
      meeting.id = stored.id
      guard meeting != stored else { return (stored, false, outside) }
      try meetingIndex.save(meeting)
      return (meeting, true, outside)
    }
    // Somebody else's edit is announced here even when this change changed nothing: this
    // look has used up the "it changed" answer, so no later look would report it.
    if saved || editedOutside { hub.send(.meetings) }
    if editedOutside, !saved { meetingIndex.refreshNotes(for: [id]) }
    return result
  }

  public func deleteMeeting(_ id: Meeting.ID) throws {
    try write(.meetings) { try meetingIndex.delete(id) }
  }

  public func audioDirectory(forMeeting id: Meeting.ID) throws -> URL {
    try meetingIndex.audioFolder(id)
  }

  // MARK: Tasks

  public func taskList() throws -> TaskList {
    try read(tasksFile, .tasks)
  }

  @discardableResult
  public func updateTaskList(_ change: @Sendable (inout TaskList) throws -> Void) throws -> TaskList {
    try write(.tasks) { try tasksFile.update(change) }
  }

  // MARK: Agents

  public func agentSessions() -> [AgentSession] {
    let sessions = agentFolder.sessions()
    // Reading may have tidied the folder, or found what another process wrote.
    noteAgents()
    return sessions
  }

  public func save(_ session: AgentSession) throws {
    try write(.agents) { try agentFolder.save(session) }
    if agentsSeen != nil { agentsSeen = agentFolder.signature() }
  }

  /// Tells listeners when the agents folder is not what it was when last looked at.
  private func noteAgents() {
    guard let seen = agentsSeen else { return }
    let now = agentFolder.signature()
    guard now != seen else { return }
    agentsSeen = now
    hub.send(.agents)
  }

  // MARK: Changes

  public nonisolated func changes() -> AsyncStream<LibraryChange> {
    // What the folder looks like right now, so a write that lands before the watch is up
    // is still reported.
    let files = [
      FolderLayout.settings, FolderLayout.words, FolderLayout.snippets, FolderLayout.dictations,
      FolderLayout.tasks,
    ]
    let baseline = Baseline(
      moment: Date(),
      files: files.map { FileSignature.of(layout.file($0)) },
      agents: agentFolder.signature()
    )
    return hub.stream { [weak self] in
      guard let self else { return }
      Task { await self.listenersChanged(baseline) }
    }
  }

  /// The state of the folder at the moment somebody started to listen.
  private struct Baseline: Sendable {
    var moment: Date
    /// Settings, words, snippets, dictations, tasks.
    var files: [FileSignature?]
    var agents: [Int32: FileSignature]
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
    watcher.start()
    self.watcher = watcher
    // Files that were read before are compared with what was read. The rest are compared
    // with what they were when the listener arrived. Nothing slips through in between.
    settingsFile.adopt(earlier: baseline.files[0])
    wordsFile.adopt(earlier: baseline.files[1])
    snippetsFile.adopt(earlier: baseline.files[2])
    dictationsFile.adopt(earlier: baseline.files[3])
    tasksFile.adopt(earlier: baseline.files[4])
    agentsSeen = agentsSeen ?? baseline.agents
    lookForChanges(since: baseline.moment)
  }

  /// Compares the folder with what was last seen and reports the differences.
  private func lookForChanges(since moment: Date? = nil) {
    if settingsFile.poll() { hub.send(.settings) }
    if wordsFile.poll() { hub.send(.words) }
    if snippetsFile.poll() { hub.send(.snippets) }
    if dictationsFile.poll() { hub.send(.dictations) }
    if tasksFile.poll() { hub.send(.tasks) }
    noteAgents()
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
        FileAccess.removeStaleTemporaryFiles(in: layout.agentsFolder)
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
    throw SpacesError.storage(
      failed.count == 1
        ? "The history entry is gone, but its audio file \(failed[0]) could not be deleted."
        : "The history entries are gone, but \(failed.count) of their audio files could not be deleted."
    )
  }
}
