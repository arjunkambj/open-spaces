import Foundation

// MARK: - Settings

/// Everything the user can configure. Stored as one JSON document.
/// Decoding is tolerant: a missing key falls back to its default, so files
/// written by an older version keep loading.
public struct Settings: Codable, Sendable, Equatable {
  /// The name asked for during onboarding. Used in greetings and passed to the
  /// language model so it can spell the user's name.
  public var userName: String
  /// Set once the onboarding flow has been completed.
  public var onboardedAt: Date?

  /// OpenAI transcription model, e.g. `gpt-transcribe`.
  public var transcriptionModel: String
  /// OpenAI chat model used for clean-up, command mode and meeting notes.
  public var textModel: String
  /// ISO 639-1 code of the spoken language, or `nil` to auto-detect.
  public var language: String?
  /// Base URL of an OpenAI-compatible server, or `nil` for `https://api.openai.com/v1`.
  /// Lets people point the app at a proxy or a local model server.
  public var apiBaseURL: String?

  /// When on, the raw transcript is polished by the language model
  /// (filler words removed, punctuation fixed, style applied).
  public var smartFormatting: Bool
  /// Writing style per kind of app.
  public var styles: [AppCategory: WritingStyle]

  /// Global keyboard shortcuts (macOS).
  public var shortcuts: [ShortcutAction: KeyCombo]
  /// Unique ID of the chosen input device, or `nil` for the system default.
  public var microphoneID: String?
  public var playSounds: Bool
  public var showPill: Bool
  public var launchAtLogin: Bool
  /// Keep audio of dictations so a failed one can be retried.
  public var keepDictationAudio: Bool
  /// How long dictation history is kept.
  public var historyRetention: HistoryRetention

  public var meetings: MeetingSettings

  public init(
    userName: String = "",
    onboardedAt: Date? = nil,
    transcriptionModel: String = Settings.defaultTranscriptionModel,
    textModel: String = Settings.defaultTextModel,
    language: String? = nil,
    apiBaseURL: String? = nil,
    smartFormatting: Bool = true,
    styles: [AppCategory: WritingStyle] = Settings.defaultStyles,
    shortcuts: [ShortcutAction: KeyCombo] = Settings.defaultShortcuts,
    microphoneID: String? = nil,
    playSounds: Bool = true,
    showPill: Bool = true,
    launchAtLogin: Bool = false,
    keepDictationAudio: Bool = true,
    historyRetention: HistoryRetention = .forever,
    meetings: MeetingSettings = MeetingSettings()
  ) {
    self.userName = userName
    self.onboardedAt = onboardedAt
    self.transcriptionModel = transcriptionModel
    self.textModel = textModel
    self.language = language
    self.apiBaseURL = apiBaseURL
    self.smartFormatting = smartFormatting
    self.styles = styles
    self.shortcuts = shortcuts
    self.microphoneID = microphoneID
    self.playSounds = playSounds
    self.showPill = showPill
    self.launchAtLogin = launchAtLogin
    self.keepDictationAudio = keepDictationAudio
    self.historyRetention = historyRetention
    self.meetings = meetings
  }

  public static let defaultTranscriptionModel = "gpt-transcribe"
  public static let defaultTextModel = "gpt-6-luna"
  /// Models offered in pickers. The fields stay free-text so any model works.
  public static let suggestedTranscriptionModels = ["gpt-transcribe", "whisper-1"]
  public static let suggestedTextModels = ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.2-sol", "gpt-6.2-astra"]

  public static let defaultStyles: [AppCategory: WritingStyle] = [
    .personalMessages: .casual,
    .workMessages: .casual,
    .email: .formal,
    .other: .formal,
  ]

  public static let defaultShortcuts: [ShortcutAction: KeyCombo] = [
    .pushToTalk: KeyCombo(modifiers: [.function]),
    .handsFree: KeyCombo(keyCode: KeyCombo.KeyCode.space, modifiers: [.function]),
    .commandMode: KeyCombo(modifiers: [.function, .control]),
    .pasteLast: KeyCombo(keyCode: KeyCombo.KeyCode.v, modifiers: [.control, .command]),
    .toggleMeeting: KeyCombo(keyCode: KeyCombo.KeyCode.m, modifiers: [.control, .option]),
  ]

  public var isOnboarded: Bool { onboardedAt != nil }

  public func style(for category: AppCategory) -> WritingStyle {
    styles[category] ?? Settings.defaultStyles[category] ?? .formal
  }

  public func shortcut(for action: ShortcutAction) -> KeyCombo? {
    shortcuts[action]
  }

  private enum CodingKeys: String, CodingKey {
    case userName, onboardedAt, transcriptionModel, textModel, language, apiBaseURL, smartFormatting, styles
    case shortcuts
    case microphoneID, playSounds, showPill, launchAtLogin, keepDictationAudio, historyRetention, meetings
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Settings()
    userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
    onboardedAt = try c.decodeIfPresent(Date.self, forKey: .onboardedAt)
    transcriptionModel =
      try c.decodeIfPresent(String.self, forKey: .transcriptionModel) ?? d.transcriptionModel
    textModel = try c.decodeIfPresent(String.self, forKey: .textModel) ?? d.textModel
    language = try c.decodeIfPresent(String.self, forKey: .language)
    apiBaseURL = try c.decodeIfPresent(String.self, forKey: .apiBaseURL)
    smartFormatting = try c.decodeIfPresent(Bool.self, forKey: .smartFormatting) ?? d.smartFormatting
    let rawStyles = try c.decodeIfPresent([String: WritingStyle].self, forKey: .styles) ?? [:]
    var styles = d.styles
    for (key, value) in rawStyles {
      if let category = AppCategory(rawValue: key) { styles[category] = value }
    }
    self.styles = styles
    let rawShortcuts = try c.decodeIfPresent([String: KeyCombo].self, forKey: .shortcuts) ?? [:]
    var shortcuts = d.shortcuts
    for (key, value) in rawShortcuts {
      if let action = ShortcutAction(rawValue: key) { shortcuts[action] = value }
    }
    self.shortcuts = shortcuts
    microphoneID = try c.decodeIfPresent(String.self, forKey: .microphoneID)
    playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
    showPill = try c.decodeIfPresent(Bool.self, forKey: .showPill) ?? d.showPill
    launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    keepDictationAudio = try c.decodeIfPresent(Bool.self, forKey: .keepDictationAudio) ?? d.keepDictationAudio
    historyRetention =
      try c.decodeIfPresent(HistoryRetention.self, forKey: .historyRetention) ?? d.historyRetention
    meetings = try c.decodeIfPresent(MeetingSettings.self, forKey: .meetings) ?? d.meetings
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(userName, forKey: .userName)
    try c.encodeIfPresent(onboardedAt, forKey: .onboardedAt)
    try c.encode(transcriptionModel, forKey: .transcriptionModel)
    try c.encode(textModel, forKey: .textModel)
    try c.encodeIfPresent(language, forKey: .language)
    try c.encodeIfPresent(apiBaseURL, forKey: .apiBaseURL)
    try c.encode(smartFormatting, forKey: .smartFormatting)
    // Written as plain string-keyed objects so the JSON stays readable.
    try c.encode(
      Dictionary(uniqueKeysWithValues: styles.map { ($0.key.rawValue, $0.value) }),
      forKey: .styles
    )
    try c.encode(
      Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) }),
      forKey: .shortcuts
    )
    try c.encodeIfPresent(microphoneID, forKey: .microphoneID)
    try c.encode(playSounds, forKey: .playSounds)
    try c.encode(showPill, forKey: .showPill)
    try c.encode(launchAtLogin, forKey: .launchAtLogin)
    try c.encode(keepDictationAudio, forKey: .keepDictationAudio)
    try c.encode(historyRetention, forKey: .historyRetention)
    try c.encode(meetings, forKey: .meetings)
  }
}

public struct MeetingSettings: Codable, Sendable, Equatable {
  /// Record what the computer plays (the other people on a call) as well as the microphone. macOS only.
  public var captureSystemAudio: Bool
  /// Write AI notes (summary, decisions, action items) when a recording ends.
  public var autoSummarize: Bool
  /// Keep the audio files after the transcript is made.
  public var keepAudio: Bool

  public init(captureSystemAudio: Bool = true, autoSummarize: Bool = true, keepAudio: Bool = true) {
    self.captureSystemAudio = captureSystemAudio
    self.autoSummarize = autoSummarize
    self.keepAudio = keepAudio
  }

  private enum CodingKeys: String, CodingKey { case captureSystemAudio, autoSummarize, keepAudio }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    captureSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? true
    autoSummarize = try c.decodeIfPresent(Bool.self, forKey: .autoSummarize) ?? true
    keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? true
  }
}

public enum HistoryRetention: String, Codable, Sendable, CaseIterable {
  case forever, month, week, day, never

  /// Entries older than this many seconds are removed. `nil` keeps everything; `0` keeps nothing.
  public var maxAge: TimeInterval? {
    switch self {
    case .forever: nil
    case .month: 30 * 86_400
    case .week: 7 * 86_400
    case .day: 86_400
    case .never: 0
    }
  }

  public var label: String {
    switch self {
    case .forever: "Forever"
    case .month: "30 days"
    case .week: "7 days"
    case .day: "24 hours"
    case .never: "Don't keep history"
    }
  }
}

// MARK: - Style

/// The kind of app the user is dictating into. Decides which writing style applies.
public enum AppCategory: String, Codable, Sendable, CaseIterable, Hashable {
  case personalMessages, workMessages, email, other

  public var label: String {
    switch self {
    case .personalMessages: "Personal messages"
    case .workMessages: "Work messages"
    case .email: "Email"
    case .other: "Everything else"
    }
  }
}

public enum WritingStyle: String, Codable, Sendable, CaseIterable, Hashable {
  case formal, casual, veryCasual

  public var label: String {
    switch self {
    case .formal: "Formal"
    case .casual: "Casual"
    case .veryCasual: "Very casual"
    }
  }

  /// One line shown under the label.
  public var summary: String {
    switch self {
    case .formal: "Caps + punctuation"
    case .casual: "Caps + less punctuation"
    case .veryCasual: "No caps + less punctuation"
    }
  }

  /// A sample of how the same sentence comes out in this style.
  public var example: String {
    switch self {
    case .formal: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
    case .casual: "Hey are you free for lunch tomorrow? Let's do 12 if that works for you"
    case .veryCasual: "hey are you free for lunch tomorrow? let's do 12 if that works for you"
    }
  }
}

// MARK: - Shortcuts

public enum ShortcutAction: String, Codable, Sendable, CaseIterable, Hashable {
  /// Hold to dictate, release to insert.
  case pushToTalk
  /// Press once to start dictating, press again to stop.
  case handsFree
  /// Hold, speak an instruction, and the selected text is rewritten.
  case commandMode
  /// Paste the most recent dictation again.
  case pasteLast
  /// Start or stop a meeting recording.
  case toggleMeeting

  public var label: String {
    switch self {
    case .pushToTalk: "Push to talk"
    case .handsFree: "Hands-free mode"
    case .commandMode: "Command mode"
    case .pasteLast: "Paste last transcript"
    case .toggleMeeting: "Start or stop meeting recording"
    }
  }

  public var help: String {
    switch self {
    case .pushToTalk: "Hold to dictate. Release to insert the text."
    case .handsFree: "Press once to start dictating. Press again to stop."
    case .commandMode: "Select text, hold, and say how to change it."
    case .pasteLast: "Insert your most recent dictation again."
    case .toggleMeeting: "Record a meeting from anywhere."
    }
  }
}

/// A keyboard shortcut: an optional key plus modifiers. A combo with no key is
/// "modifiers only" (for example holding fn).
public struct KeyCombo: Codable, Sendable, Hashable {
  /// macOS virtual key code (`kVK_*`), or `nil` for a modifiers-only combo.
  public var keyCode: UInt16?
  public var modifiers: Set<Modifier>

  public init(keyCode: UInt16? = nil, modifiers: Set<Modifier> = []) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  public enum Modifier: String, Codable, Sendable, Hashable, CaseIterable {
    case function, control, option, shift, command

    public var symbol: String {
      switch self {
      case .function: "fn"
      case .control: "⌃"
      case .option: "⌥"
      case .shift: "⇧"
      case .command: "⌘"
      }
    }
  }

  /// The few virtual key codes the defaults need.
  public enum KeyCode {
    public static let space: UInt16 = 49
    public static let v: UInt16 = 9
    public static let m: UInt16 = 46
    public static let escape: UInt16 = 53
  }

  public var isEmpty: Bool { keyCode == nil && modifiers.isEmpty }
  public var isModifiersOnly: Bool { keyCode == nil && !modifiers.isEmpty }

  /// Modifiers in the order they are shown: fn ⌃ ⌥ ⇧ ⌘.
  public var orderedModifiers: [Modifier] {
    Modifier.allCases.filter(modifiers.contains)
  }
}

// MARK: - Dictionary and snippets

/// A word or phrase the transcriber should spell the user's way.
public struct DictionaryWord: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  /// The correct spelling, e.g. "Kubernetes".
  public var text: String
  /// Optional misheard form to replace, e.g. "cooper netties". When set, the
  /// entry also acts as a find-and-replace rule on the transcript.
  public var replaces: String?
  public var createdAt: Date

  public init(id: UUID = UUID(), text: String, replaces: String? = nil, createdAt: Date = Date()) {
    self.id = id
    self.text = text
    self.replaces = replaces
    self.createdAt = createdAt
  }
}

/// A voice shortcut: say the trigger, get the expansion.
public struct Snippet: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  /// What the user says, e.g. "my calendar link".
  public var trigger: String
  /// What gets inserted, e.g. "https://cal.com/me".
  public var expansion: String
  public var createdAt: Date

  public init(id: UUID = UUID(), trigger: String, expansion: String, createdAt: Date = Date()) {
    self.id = id
    self.trigger = trigger
    self.expansion = expansion
    self.createdAt = createdAt
  }
}

// MARK: - Dictation

public enum DictationMode: String, Codable, Sendable {
  case dictation, command
}

/// One finished (or failed) dictation, as kept in history.
public struct Dictation: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var createdAt: Date
  public var mode: DictationMode
  /// What the transcriber heard, before any clean-up.
  public var rawText: String
  /// The final text that was inserted.
  public var text: String
  /// Length of the audio in seconds.
  public var duration: TimeInterval
  /// Name of the app the text went into, when known.
  public var appName: String?
  public var bundleID: String?
  /// File name of the kept audio inside the library's dictation audio folder.
  public var audioFile: String?
  /// Set when processing failed. `text` is then empty and the audio is kept for a retry.
  public var failure: String?

  public init(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    mode: DictationMode = .dictation,
    rawText: String,
    text: String,
    duration: TimeInterval,
    appName: String? = nil,
    bundleID: String? = nil,
    audioFile: String? = nil,
    failure: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.mode = mode
    self.rawText = rawText
    self.text = text
    self.duration = duration
    self.appName = appName
    self.bundleID = bundleID
    self.audioFile = audioFile
    self.failure = failure
  }

  public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
  public var failed: Bool { failure != nil }
}

/// Where a dictation is going. Lets the engine pick a writing style.
public struct DictationContext: Sendable, Equatable {
  public var appName: String?
  public var bundleID: String?
  public var category: AppCategory

  public init(appName: String? = nil, bundleID: String? = nil, category: AppCategory = .other) {
    self.appName = appName
    self.bundleID = bundleID
    self.category = category
  }
}

/// Numbers shown on the home screen.
public struct DictationStats: Sendable, Equatable {
  public var totalWords: Int
  /// Average speaking speed across history, words per minute.
  public var wordsPerMinute: Int
  /// Consecutive days with at least one dictation, ending today or yesterday.
  public var dayStreak: Int
  public var dictationCount: Int

  public init(totalWords: Int = 0, wordsPerMinute: Int = 0, dayStreak: Int = 0, dictationCount: Int = 0) {
    self.totalWords = totalWords
    self.wordsPerMinute = wordsPerMinute
    self.dayStreak = dayStreak
    self.dictationCount = dictationCount
  }

  public init(_ dictations: [Dictation], now: Date = Date(), calendar: Calendar = .current) {
    let done = dictations.filter { !$0.failed }
    let words = done.reduce(0) { $0 + $1.wordCount }
    let seconds = done.reduce(0.0) { $0 + $1.duration }
    let days = Set(done.map { calendar.startOfDay(for: $0.createdAt) })
    var streak = 0
    var day = calendar.startOfDay(for: now)
    if !days.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
      day = yesterday
    }
    while days.contains(day) {
      streak += 1
      guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
      day = previous
    }
    self.init(
      totalWords: words,
      wordsPerMinute: seconds > 0 ? Int((Double(words) / (seconds / 60)).rounded()) : 0,
      dayStreak: streak,
      dictationCount: done.count
    )
  }
}

// MARK: - Meetings

public enum Speaker: Codable, Sendable, Hashable {
  /// The microphone: the person using the app.
  case me
  /// The computer's audio: everyone else on the call.
  case others
  case named(String)

  public var label: String {
    switch self {
    case .me: "Me"
    case .others: "Others"
    case .named(let name): name
    }
  }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    switch raw {
    case "me": self = .me
    case "others": self = .others
    default: self = .named(raw)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .me: try c.encode("me")
    case .others: try c.encode("others")
    case .named(let name): try c.encode(name)
    }
  }
}

public struct TranscriptSegment: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var speaker: Speaker
  /// Seconds from the start of the recording.
  public var start: TimeInterval
  public var end: TimeInterval
  public var text: String

  public init(id: UUID = UUID(), speaker: Speaker, start: TimeInterval, end: TimeInterval, text: String) {
    self.id = id
    self.speaker = speaker
    self.start = start
    self.end = end
    self.text = text
  }
}

public struct ActionItem: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var text: String
  public var owner: String?
  public var done: Bool

  public init(id: UUID = UUID(), text: String, owner: String? = nil, done: Bool = false) {
    self.id = id
    self.text = text
    self.owner = owner
    self.done = done
  }
}

/// Notes the language model writes from a transcript.
public struct MeetingNotes: Codable, Sendable, Hashable {
  public var summary: String
  public var keyPoints: [String]
  public var decisions: [String]
  public var actionItems: [ActionItem]

  public init(
    summary: String = "",
    keyPoints: [String] = [],
    decisions: [String] = [],
    actionItems: [ActionItem] = []
  ) {
    self.summary = summary
    self.keyPoints = keyPoints
    self.decisions = decisions
    self.actionItems = actionItems
  }
}

public enum MeetingStatus: String, Codable, Sendable {
  case recording, processing, ready, failed
}

public struct Meeting: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var title: String
  public var startedAt: Date
  public var endedAt: Date?
  public var status: MeetingStatus
  /// Why processing failed, when `status == .failed`.
  public var failure: String?
  public var segments: [TranscriptSegment]
  /// AI notes. `nil` until they have been generated.
  public var notes: MeetingNotes?
  /// Free-form Markdown written by the user or by an agent.
  public var userNotes: String
  public var tags: [String]

  public init(
    id: UUID = UUID(),
    title: String,
    startedAt: Date = Date(),
    endedAt: Date? = nil,
    status: MeetingStatus = .recording,
    failure: String? = nil,
    segments: [TranscriptSegment] = [],
    notes: MeetingNotes? = nil,
    userNotes: String = "",
    tags: [String] = []
  ) {
    self.id = id
    self.title = title
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.status = status
    self.failure = failure
    self.segments = segments
    self.notes = notes
    self.userNotes = userNotes
    self.tags = tags
  }

  public var duration: TimeInterval {
    if let endedAt { return endedAt.timeIntervalSince(startedAt) }
    return segments.map(\.end).max() ?? 0
  }

  /// The transcript as plain text, one line per segment: `[mm:ss] Speaker: text`.
  public var transcriptText: String {
    segments.sorted { $0.start < $1.start }.map { segment in
      let total = Int(segment.start)
      let stamp = String(format: "%02d:%02d", total / 60, total % 60)
      return "[\(stamp)] \(segment.speaker.label): \(segment.text)"
    }.joined(separator: "\n")
  }

  /// The meeting as a Markdown document: title, date, summary, key points,
  /// decisions, action items, the user's notes and the transcript.
  public func markdown(timeZone: TimeZone = .current) -> String {
    let dateFormat = DateFormatter()
    dateFormat.locale = Locale(identifier: "en_US_POSIX")
    dateFormat.timeZone = timeZone
    dateFormat.dateFormat = "yyyy-MM-dd HH:mm"
    var lines = ["# \(title)", ""]
    var facts = ["**Date:** \(dateFormat.string(from: startedAt))"]
    if duration > 0 { facts.append("**Length:** \(max(1, Int((duration / 60).rounded()))) min") }
    if !tags.isEmpty { facts.append("**Tags:** \(tags.joined(separator: ", "))") }
    lines.append(facts.joined(separator: "  \n"))
    func section(_ heading: String, _ body: [String]) {
      guard !body.isEmpty else { return }
      lines += ["", "## \(heading)", ""] + body
    }
    if let notes {
      if !notes.summary.isEmpty { section("Summary", [notes.summary]) }
      section("Key points", notes.keyPoints.map { "- \($0)" })
      section("Decisions", notes.decisions.map { "- \($0)" })
      section(
        "Action items",
        notes.actionItems.map { item in
          "- [\(item.done ? "x" : " ")] \(item.text)" + (item.owner.map { " (\($0))" } ?? "")
        }
      )
    }
    if !userNotes.isEmpty { section("My notes", [userNotes]) }
    if !segments.isEmpty { section("Transcript", [transcriptText]) }
    return lines.joined(separator: "\n") + "\n"
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, startedAt, endedAt, status, failure, segments, notes, userNotes, tags
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled meeting"
    startedAt = try c.decode(Date.self, forKey: .startedAt)
    endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
    status = try c.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .ready
    failure = try c.decodeIfPresent(String.self, forKey: .failure)
    segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
    notes = try c.decodeIfPresent(MeetingNotes.self, forKey: .notes)
    userNotes = try c.decodeIfPresent(String.self, forKey: .userNotes) ?? ""
    tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
  }
}

// MARK: - Languages

public struct SpokenLanguage: Sendable, Hashable, Identifiable {
  /// ISO 639-1 code.
  public var code: String
  public var name: String
  public var id: String { code }

  public static let all: [SpokenLanguage] = [
    ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("hi", "Hindi"),
    ("pt", "Portuguese"), ("it", "Italian"), ("nl", "Dutch"), ("ja", "Japanese"), ("ko", "Korean"),
    ("zh", "Chinese"), ("ar", "Arabic"), ("ru", "Russian"), ("tr", "Turkish"), ("pl", "Polish"),
    ("sv", "Swedish"), ("da", "Danish"), ("nb", "Norwegian"), ("fi", "Finnish"), ("id", "Indonesian"),
    ("vi", "Vietnamese"), ("th", "Thai"), ("uk", "Ukrainian"), ("he", "Hebrew"), ("el", "Greek"),
    ("cs", "Czech"), ("ro", "Romanian"), ("hu", "Hungarian"), ("bn", "Bengali"), ("ta", "Tamil"),
    ("te", "Telugu"), ("mr", "Marathi"), ("gu", "Gujarati"), ("pa", "Punjabi"), ("ur", "Urdu"),
  ].map { SpokenLanguage(code: $0.0, name: $0.1) }
}
