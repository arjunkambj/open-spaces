import Foundation
import WisperDomain

/// The `LiveTranscriber` that streams sound to the realtime API (`realtime?intent=transcription`).
///
/// One WebSocket per recording. After it opens, the session is set up for transcription only
/// (no spoken answers, and no guessing where a turn ends: the recording ends when the person
/// lets go of the key). Sound goes out as it is captured, as 24 kHz 16-bit samples. `finish`
/// commits the sound and waits for the text of exactly that commit.
///
/// This is for `gpt-live-transcribe`, the model that writes text while the sound arrives, so
/// that little is left to do when the person stops. (`gpt-transcribe` can run in such a session
/// too, but only starts once the sound is committed. That saves the upload and nothing else,
/// so it stays on the file path.) Any other model, a server that does not speak this
/// protocol, and every failure on the way make `open` or `finish` throw. The caller then
/// transcribes the recorded file instead.
///
/// The key travels in the handshake to the server the settings name, and only when it was
/// saved for that server, exactly as with every other request.
struct OpenAILiveTranscriber: LiveTranscriber {
  let client: Client

  /// How long the server gets to accept the connection and the settings. The person is
  /// speaking meanwhile, so this costs them nothing; past it, the file is used.
  static let openTime: TimeInterval = 5
  /// How long `finish` waits for the text when nobody ends the session sooner.
  static let finishTime: TimeInterval = 30

  func open(_ request: LiveTranscriptionRequest) async throws -> any LiveTranscription {
    guard let model = Realtime.model(named: request.model) else { throw Realtime.unavailable }
    let words = Hints.words(request.vocabulary)
    var language = request.language?.trimmingCharacters(in: .whitespaces).lowercased()
    if language?.isEmpty == true { language = nil }
    // The app lists Norwegian as "nb" (Bokmål). The models know it as "no".
    let spoken = language == "nb" ? "no" : language

    var transcription: [String: Any] = ["model": model]
    if !words.isEmpty { transcription["keywords"] = words }
    if let spoken { transcription["languages"] = [spoken] }
    let setup: [String: Any] = [
      "type": "session.update",
      "session": [
        "type": "transcription",
        "audio": [
          "input": [
            "format": ["type": "audio/pcm", "rate": Int(Realtime.sampleRate)],
            "transcription": transcription,
            "turn_detection": NSNull(),
          ]
        ],
      ],
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: setup) else { throw Realtime.unavailable }

    let socket = try await client.socket(
      path: "realtime",
      query: [URLQueryItem(name: "intent", value: "transcription")]
    )
    let session = RealtimeSession(socket: socket, words: words, language: language)
    do {
      try await session.begin(setup: String(decoding: json, as: UTF8.self))
    } catch {
      session.cancel()
      throw error
    }
    return session
  }
}

enum Realtime {
  /// The rate the sound is sent at: the one the API's own examples use.
  static let sampleRate = 24_000.0

  /// Thrown for every way a live session can fail. The caller falls back to the file, so the
  /// person never reads this.
  static let unavailable = WisperError.network("live transcription is not available")

  /// The model to ask for, or `nil` when `name` is not one that can transcribe live.
  static func model(named name: String) -> String? {
    // "openai/gpt-live-transcribe" on a relay is still gpt-live-transcribe.
    let last = name.lowercased().split(separator: "/").last.map(String.init) ?? ""
    return last.hasPrefix(liveModel) ? name : nil
  }

  static let liveModel = "gpt-live-transcribe"

  /// The model to upload a file to when the person chose `name`. The live model does not take
  /// files, so its sibling that does stands in for it (for a retry, and for meetings).
  static func fileModel(for name: String) -> String {
    var parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard let last = parts.last, last.lowercased().hasPrefix(liveModel) else { return name }
    parts[parts.count - 1] = "gpt-transcribe"
    return parts.joined(separator: "/")
  }
}

// MARK: - One session

/// `@unchecked Sendable`: `tasks` is read and written while holding `lock`; everything else is
/// constant, or `Sendable` itself.
private final class RealtimeSession: LiveTranscription, @unchecked Sendable {
  let partials: AsyncStream<String>
  private let partialFeed: AsyncStream<String>.Continuation
  private let socket: URLSessionWebSocketTask
  private let outbox: AsyncStream<Outgoing>.Continuation
  private let waiting: AsyncStream<Outgoing>
  private let state = RealtimeState()
  private let words: [String]
  private let language: String?
  private let lock = NSLock()
  private var tasks: [Task<Void, Never>] = []

  private enum Outgoing: Sendable {
    case sound(AudioFrames)
    case commit
  }

  /// How many runs of sound may wait to be sent: several minutes' worth. A connection that
  /// has fallen that far behind is of no use, and the session fails rather than grow without end.
  static let mostWaiting = 6_000

  init(socket: URLSessionWebSocketTask, words: [String], language: String?) {
    self.socket = socket
    self.words = words
    self.language = language
    (partials, partialFeed) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
    (waiting, outbox) = AsyncStream.makeStream(
      of: Outgoing.self,
      bufferingPolicy: .bufferingOldest(RealtimeSession.mostWaiting)
    )
  }

  deinit {
    // Dropped without `finish` or `cancel`: nothing may keep sending.
    for task in tasks { task.cancel() }
    socket.cancel(with: .goingAway, reason: nil)
  }

  /// Opens the connection, sends the settings and returns once the server has taken them.
  func begin(setup: String) async throws {
    socket.resume()
    let state = state
    let socket = socket
    let partialFeed = partialFeed
    keep(
      Task {
        while !Task.isCancelled {
          do {
            guard case .string(let text) = try await socket.receive() else { continue }
            if let heard = await state.take(RealtimeEvent(text)) { partialFeed.yield(heard) }
          } catch {
            await state.fail()
            return
          }
        }
      }
    )
    let giveUp = Task {
      try? await Task.sleep(for: .seconds(OpenAILiveTranscriber.openTime))
      if !Task.isCancelled { await state.fail() }
    }
    defer { giveUp.cancel() }
    do {
      try await socket.send(.string(setup))
    } catch {
      throw Realtime.unavailable
    }
    try await state.untilReady()

    let waiting = waiting
    keep(
      Task {
        var resampler = Upsampler(to: Realtime.sampleRate)
        for await item in waiting {
          let message: String
          switch item {
          case .sound(let frames):
            let sound = resampler.convert(frames)
            if sound.isEmpty { continue }
            message = #"{"type":"input_audio_buffer.append","audio":""# + sound.base64EncodedString() + #""}"#
          case .commit:
            message = #"{"type":"input_audio_buffer.commit"}"#
          }
          do {
            try await socket.send(.string(message))
          } catch {
            await state.fail()
            return
          }
        }
      }
    )
  }

  func send(_ frames: AudioFrames) {
    guard !frames.samples.isEmpty else { return }
    if case .dropped = outbox.yield(.sound(frames)) {
      // Sound is missing from here on, so the text could not be whole.
      let state = state
      Task { await state.fail() }
    }
  }

  func finish() async throws -> Transcript {
    outbox.yield(.commit)
    outbox.finish()
    let state = state
    let giveUp = Task {
      try? await Task.sleep(for: .seconds(OpenAILiveTranscriber.finishTime))
      if !Task.isCancelled { await state.fail() }
    }
    defer {
      giveUp.cancel()
      close()
    }
    var transcript = try await state.result()
    transcript.text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    // The same two checks the file path makes: sounds written out as words, and the hint list read back.
    if Silence.isNoise(transcript.text) || Silence.isEcho(transcript.text, of: words) { transcript.text = "" }
    if transcript.language == nil { transcript.language = language }
    return transcript
  }

  func cancel() {
    let state = state
    Task { await state.fail() }
    close()
  }

  private func keep(_ task: Task<Void, Never>) {
    lock.withLock { tasks.append(task) }
  }

  private func close() {
    outbox.finish()
    partialFeed.finish()
    let running = lock.withLock { () -> [Task<Void, Never>] in
      defer { tasks = [] }
      return tasks
    }
    for task in running { task.cancel() }
    socket.cancel(with: .normalClosure, reason: nil)
  }
}

/// What the server said, cut down to what the session needs.
private enum RealtimeEvent: Sendable {
  /// The settings were taken.
  case ready
  /// The sound was committed as this item.
  case committed(item: String)
  case delta(item: String, text: String)
  case completed(item: String, text: String, language: String?)
  /// The server reported an error, for one item or for the session.
  case failed
  case other

  init(_ text: String) {
    guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let type = json["type"] as? String
    else {
      self = .other
      return
    }
    let item = json["item_id"] as? String ?? ""
    switch type {
    case "session.updated", "transcription_session.updated":
      self = .ready
    case "input_audio_buffer.committed":
      self = .committed(item: item)
    case "conversation.item.input_audio_transcription.delta":
      self = .delta(item: item, text: json["delta"] as? String ?? "")
    case "conversation.item.input_audio_transcription.completed":
      let languages = json["languages"] as? [[String: Any]]
      self = .completed(
        item: item,
        text: json["transcript"] as? String ?? "",
        language: languages?.first?["code"] as? String
      )
    case "conversation.item.input_audio_transcription.failed", "error":
      self = .failed
    default:
      self = .other
    }
  }
}

/// Where a session stands. Everything that waits for the server waits here.
private actor RealtimeState {
  private var ready = false
  private var failed = false
  private var committed: String?
  private var finished: [String: Transcript] = [:]
  private var heard: [(item: String, text: String)] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []

  /// Takes in one event. Returns the text heard so far when the event added to it.
  func take(_ event: RealtimeEvent) -> String? {
    switch event {
    case .ready:
      ready = true
    case .committed(let item):
      committed = item
    case .delta(let item, let text):
      if let index = heard.firstIndex(where: { $0.item == item }) {
        heard[index].text += text
      } else {
        heard.append((item, text))
      }
      return heard.map(\.text).joined(separator: " ")
    case .completed(let item, let text, let language):
      finished[item] = Transcript(text: text, language: language)
    case .failed:
      failed = true
    case .other:
      return nil
    }
    wake()
    return nil
  }

  func fail() {
    failed = true
    wake()
  }

  func untilReady() async throws {
    while !ready, !failed { await next() }
    if failed { throw Realtime.unavailable }
  }

  /// The text of the sound that was committed.
  func result() async throws -> Transcript {
    while !failed {
      if let committed, let transcript = finished[committed] { return transcript }
      await next()
    }
    throw Realtime.unavailable
  }

  private func next() async {
    await withCheckedContinuation { waiters.append($0) }
  }

  private func wake() {
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume() }
  }
}

/// Turns runs of sound into 16-bit samples at another rate, joining the runs without a seam.
struct Upsampler {
  private let target: Double
  /// Where the next output sample falls, counted in input samples from the start of the next run.
  private var position = 0.0
  private var last: Float?

  init(to target: Double) { self.target = target }

  /// The sound as 16-bit little-endian samples at the target rate.
  mutating func convert(_ frames: AudioFrames) -> Data {
    let samples = frames.samples
    guard !samples.isEmpty, frames.sampleRate > 0 else { return Data() }
    let step = frames.sampleRate / target
    let count = samples.count
    var data = Data(capacity: Int(Double(count) / step + 2) * 2)
    while position <= Double(count - 1) {
      let index = Int(position.rounded(.down))
      let fraction = Float(position - Double(index))
      // Before the first sample of this run sits the last one of the run before.
      let from = index < 0 ? (last ?? samples[0]) : samples[index]
      let to = samples[min(index + 1, count - 1)]
      let value = max(-1, min(1, from + (to - from) * fraction))
      let whole = Int16((value * 32_767).rounded())
      withUnsafeBytes(of: whole.littleEndian) { data.append(contentsOf: $0) }
      position += step
    }
    position -= Double(count)
    last = samples[count - 1]
    return data
  }
}
