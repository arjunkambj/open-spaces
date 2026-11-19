import Foundation
import WisperDomain

/// Turns one recording into the text to insert.
///
/// Transcribes, applies the dictionary, then either tidies the words
/// (dictation) or carries out the spoken instruction (command mode). It reads
/// from the library but changes nothing: looking at the target, inserting and
/// saving are the engine's job.
struct DictationPipeline: Sendable {
  let library: any Library
  let transcriber: any Transcriber
  let languageModel: any LanguageModel

  /// What is known about a dictation so far. Filled in step by step, so a
  /// failure half-way still carries everything learned before it.
  struct Draft: Sendable {
    /// Where the text is going.
    var context = DictationContext()
    /// The settings in force, once they have been read.
    var settings: Settings?
    /// What the transcriber heard.
    var raw = ""
    /// The text to insert.
    var text = ""

    /// With history turned off nothing about a dictation stays on disk, audio included.
    var keepsHistory: Bool { settings?.historyRetention != .never }
    var keepsAudio: Bool { keepsHistory && settings?.keepDictationAudio == true }
    /// The server the requests went to, so an error can name it.
    var server: APIServer { (try? settings?.apiServer()) ?? .openAI }
  }

  enum Outcome: Sendable {
    /// The recording held no speech.
    case silence
    case written(Draft)
    /// No text could be made. The draft holds what was learned before the error.
    case failed(Draft, any Error)
  }

  /// Short dictations are not sent for clean-up: there is nothing to tidy in
  /// a word or two, and a model is most tempted to answer them ("yes", "thanks").
  static let wordsWorthCleaning = 3

  /// The most text a command's answer may hold. A rewrite of a few sentences that comes back
  /// as pages of text is a model gone wrong (or steered by what was selected), and typing it
  /// into the person's document would do harm. Room is left for writing something new, and for
  /// a long selection that grows.
  static func longestReply(toSelectionOf length: Int) -> Int {
    max(4_000, 2 * length + 2_000)
  }

  /// - Parameters:
  ///   - context: where the text is going.
  ///   - selection: for a command, the text it is to change. Empty when it is to write something new.
  ///   - cleanUpLimit: the longest the tidying of a dictation may take, in seconds. After that
  ///     the words go in as they were heard.
  func run(
    audio: URL,
    mode: DictationMode,
    context: DictationContext,
    selection: String,
    cleanUpLimit: TimeInterval
  ) async -> Outcome {
    var draft = Draft(context: context)
    do {
      let settings = try await library.settings()
      draft.settings = settings
      // A server address that is set but cannot be used stops here: nothing is sent anywhere,
      // and certainly not to OpenAI instead.
      _ = try settings.apiServer()
      let words = try await library.words()
      let snippets = mode == .dictation ? try await library.snippets() : []
      let spellings = Self.unique(words.map(\.text))

      let transcript = try await transcriber.transcribe(
        TranscriptionRequest(
          audio: audio,
          model: settings.transcriptionModel,
          language: Self.clean(settings.language),
          vocabulary: Self.unique(spellings + [settings.userName])
        )
      )
      try Task.checkCancellation()
      draft.raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !draft.raw.isEmpty else { return .silence }

      let heard = DictationText.corrections(from: words).apply(to: draft.raw)
      let setting = DictationPrompts.Setting(
        style: settings.style(for: draft.context.category),
        context: draft.context,
        spellings: spellings,
        userName: settings.userName.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      switch mode {
      case .dictation:
        draft.text = await dictated(
          heard,
          settings: settings,
          setting: setting,
          snippets: snippets,
          limit: cleanUpLimit
        )
      case .command:
        draft.text = try await commanded(heard, selection: selection, settings: settings, setting: setting)
      }
      try Task.checkCancellation()
      return .written(draft)
    } catch WisperError.noSpeech {
      return .silence
    } catch {
      return .failed(draft, error)
    }
  }

  /// The words that were said, tidied, with snippets expanded. Never fails:
  /// when the model cannot be used, the person still gets what they said.
  private func dictated(
    _ heard: String,
    settings: Settings,
    setting: DictationPrompts.Setting,
    snippets: [Snippet],
    limit: TimeInterval
  ) async -> String {
    let expansions = DictationText.expansions(from: snippets)
    if let snippet = expansions.whole(heard) { return snippet }

    var text = DictationText.tidy(heard, style: setting.style, spellings: setting.spellings)
    if settings.smartFormatting, DictationText.wordCount(heard) >= Self.wordsWorthCleaning {
      let prompt = DictationPrompts.cleanUp(
        transcript: heard,
        setting: setting,
        keep: expansions.found(in: heard)
      )
      // No temperature: some models only accept their default.
      // Tidying needs no thinking, and the person is waiting: ask for the fastest answer.
      let request = CompletionRequest(
        model: settings.textModel,
        system: prompt.system,
        user: prompt.user,
        effort: CompletionRequest.Effort.none
      )
      if let reply = await reply(to: request, within: limit),
        let cleaned = DictationText.acceptedCleanUp(reply, of: heard)
      {
        text = cleaned
      }
    }
    // Snippets go in last so the model can never reword them.
    return expansions.apply(to: text)
  }

  /// The model's answer, or `nil` when it fails or takes longer than `seconds`. The words as
  /// they were heard are ready and good enough, so nobody waits long for the polish.
  private func reply(to request: CompletionRequest, within seconds: TimeInterval) async -> String? {
    let languageModel = languageModel
    // Whichever comes first, the answer or the end of the wait, is what counts. A model that
    // does not stop when asked cannot hold the text back either.
    let (answers, feed) = AsyncStream.makeStream(of: String?.self)
    let call = Task { feed.yield(try? await languageModel.complete(request)) }
    let timer = Task {
      try? await Task.sleep(for: .seconds(max(seconds, 0)))
      feed.yield(nil)
    }
    defer {
      call.cancel()
      timer.cancel()
    }
    for await answer in answers { return answer }
    return nil
  }

  /// The model's answer to a spoken instruction: the selection rewritten, or new text.
  private func commanded(
    _ instruction: String,
    selection: String,
    settings: Settings,
    setting: DictationPrompts.Setting
  ) async throws -> String {
    let selected = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    let prompt =
      selected.isEmpty
      ? DictationPrompts.compose(instruction: instruction, setting: setting)
      : DictationPrompts.rewrite(selection: selected, instruction: instruction, setting: setting)
    let reply = try await languageModel.complete(
      CompletionRequest(model: settings.textModel, system: prompt.system, user: prompt.user, effort: .low)
    )
    let text = DictationPrompts.unwrap(reply)
    guard !text.isEmpty else { throw WisperError.invalidResponse("the reply was empty") }
    // Nothing is typed when the answer is a wall of text.
    guard text.count <= Self.longestReply(toSelectionOf: selected.count) else {
      throw WisperError.replyTooLong
    }
    guard !selected.isEmpty else { return text }
    // The result replaces the selection, so put back the space or line break it began and ended with.
    let leading = selection.prefix { $0.isWhitespace }
    let trailing = String(selection.reversed().prefix { $0.isWhitespace }.reversed())
    return leading + text + trailing
  }

  private static func clean(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  /// The non-empty values, trimmed, each once, in their first order.
  private static func unique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.compactMap(clean).filter { seen.insert($0).inserted }
  }
}

/// File chores for dictation recordings. Async so they run off the main actor.
enum DictationAudio {
  /// Renames a finished recording after its dictation, so every kept file has
  /// a name of its own. Returns where the file is now.
  static func adopt(_ url: URL, for id: Dictation.ID) async -> URL {
    let kind = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
    let named = url.deletingLastPathComponent().appendingPathComponent("\(id.uuidString).\(kind)")
    do {
      try FileManager.default.moveItem(at: url, to: named)
      return named
    } catch {
      return url
    }
  }

  static func delete(_ urls: [URL]) async {
    for url in urls { try? FileManager.default.removeItem(at: url) }
  }

  static func exists(_ url: URL) async -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  /// Deletes every file in `folder` whose name is not in `names`: recordings that no history
  /// entry points at.
  static func sweep(_ folder: URL, keeping names: Set<String>) async {
    let found = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in found where !names.contains(name) {
      let url = folder.appendingPathComponent(name)
      var isFolder: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue
      else { continue }
      try? FileManager.default.removeItem(at: url)
    }
  }
}
