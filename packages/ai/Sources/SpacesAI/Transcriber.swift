import AVFoundation
import Foundation
import SpacesDomain

/// The `Transcriber` that uploads audio to `audio/transcriptions`.
///
/// What is asked for depends on the model, because the models differ:
///
///   gpt-transcribe      words go in `keywords[]`, the language in `languages[]`; no timestamps
///   gpt-live-transcribe takes no files: the file goes to `gpt-transcribe`, asked the same way
///   …whisper…           `verbose_json` with timed pieces; words go in `prompt`
///   …diarize…           `diarized_json`, which gives timed pieces, each with its speaker; takes
///                       no word hints. Known voices go in `known_speaker_names[]` and
///                       `known_speaker_references[]` (a WAV sample as a data URL)
///   anything else       words go in `prompt`, the language in `language`; no timestamps
///                       (this is `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` and unknown models)
///
/// A request that wants voices told apart (`TranscriptionRequest.voices`) always goes to
/// `voicesModel`, whatever model it names.
///
/// A hint the server refuses (a language code it does not know, a setting it
/// does not have) is left out and the audio is sent again, rather than failing
/// the dictation. Timed pieces in a reply are used whenever they are there.
struct OpenAITranscriber: Transcriber {
  let client: Client

  /// OpenAI's model that tells voices apart. OpenAI has said it will turn it off on
  /// 26 February 2027 and names no model to replace it.
  static let voicesModel = "gpt-4o-transcribe-diarize"

  func prepare() async { await client.prepare() }

  /// OpenAI's limit on one audio file.
  static let largestUpload = 25 * 1_024 * 1_024

  /// How long a file of `bytes` may take.
  ///
  /// - `wait`: how long the server may think, once it has the audio, before a try is given up.
  ///   A dictation of a few seconds normally comes back from OpenAI in about a second (a
  ///   megabyte is over four minutes of speech), so five seconds of silence means the
  ///   connection or the server is stuck: better to send it again over a new connection than
  ///   to keep the person waiting. Long recordings get more. A server of the person's own is
  ///   often a model on their own machine, far slower, and busy with one request at a time:
  ///   it gets four times as long before anything is sent twice.
  /// - `budget`: the whole call. The first try, a second one with twice the wait, and time to
  ///   send the audio twice on a slow connection (a megabyte in 20 seconds).
  static func limits(bytes: Int, openAI: Bool) -> (wait: TimeInterval, budget: TimeInterval) {
    let megabytes = Double(bytes) / 1_048_576
    let wait = openAI ? min(300, 5 + 40 * megabytes) : min(300, 20 + 60 * megabytes)
    return (wait, min(900, 3 * wait + 40 * megabytes + 10))
  }

  func transcribe(_ request: TranscriptionRequest) async throws -> Transcript {
    let size = try Upload.size(of: request.audio)
    guard size > 0 else { return Transcript(text: "", language: request.language) }
    if size > OpenAITranscriber.largestUpload, await client.usesOpenAI() {
      // OpenAI would say the same, but only after the whole file had been uploaded.
      let megabytes = Int((Double(size) / 1_048_576).rounded(.up))
      throw SpacesError.server(
        status: 413,
        message: "This recording is \(megabytes) MB. OpenAI takes audio files up to 25 MB."
      )
    }

    // A model that only works live cannot take a file. Its sibling that can stands in.
    let model = request.voices == nil ? Realtime.fileModel(for: request.model) : OpenAITranscriber.voicesModel
    let style = Style(model: model)
    let words = request.voices == nil ? Hints.words(request.vocabulary) : []
    let known = try (request.voices?.known.prefix(Voices.mostKnown) ?? []).map { sample in
      (name: sample.name, reference: try VoiceSample.dataURL(sample))
    }
    var language = request.language?.trimmingCharacters(in: .whitespaces).lowercased()
    if language?.isEmpty == true { language = nil }
    // The app lists Norwegian as "nb" (Bokmål). Whisper only knows it as "no".
    let spoken = language == "nb" ? "no" : language
    // The samples of known voices are sent, and listened to, along with the audio.
    let samples = known.reduce(0) { $0 + $1.reference.utf8.count }
    let limits = OpenAITranscriber.limits(bytes: size + samples, openAI: await client.usesOpenAI())

    let data = try await client.send(
      scope: "\(model) \(spoken ?? "")",
      optional: style.optional,
      budget: limits.budget
    ) { leftOut in
      var fields = style.fields(model: model, language: spoken, words: words, known: known)
      fields.removeAll { leftOut.contains($0.setting) }
      // Timed pieces only come with the detailed reply format, so the two go together.
      if leftOut.contains("response_format") { fields.removeAll { $0.setting == "timestamp_granularities" } }
      let upload = try Upload.write(fields: fields.map { ($0.name, $0.value) }, audio: request.audio)
      return Client.Call(
        method: "POST",
        path: "audio/transcriptions",
        body: .file(upload.file, contentType: upload.contentType),
        wait: limits.wait
      )
    }

    var transcript = try Reply(data).transcript(fallbackLanguage: language)
    if transcript.language == spoken { transcript.language = language }
    if Silence.isEcho(transcript.text, of: words) { transcript.text = "" }
    if Silence.isStockPhrase(transcript.text), Silence.isQuiet(request.audio) == true {
      transcript.text = ""
    }
    if transcript.text.isEmpty { transcript.segments = [] }
    return transcript
  }
}

// MARK: - What each model is asked for

private enum Style {
  /// `gpt-transcribe`.
  case keywords
  /// `whisper-1`, and Whisper under other names on other servers (`whisper-large-v3`).
  case timed
  /// `gpt-4o-transcribe-diarize`.
  case diarizing
  /// `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` and every model this code does not know.
  case prompted

  init(model: String) {
    // "openai/gpt-transcribe" on a relay is still gpt-transcribe.
    let name = model.lowercased().split(separator: "/").last.map(String.init) ?? ""
    if name.contains("diarize") {
      self = .diarizing
    } else if name.contains("whisper") {
      self = .timed
    } else if name.hasPrefix("gpt-transcribe") {
      self = .keywords
    } else {
      self = .prompted
    }
  }

  struct Field {
    var name: String
    var value: String
    /// The setting the field belongs to: `keywords[]` belongs to `keywords`.
    var setting: String { name.replacingOccurrences(of: "[]", with: "") }
  }

  /// Settings the request still works without.
  var optional: Set<String> {
    ["language", "languages", "keywords", "prompt", "response_format", "timestamp_granularities"]
  }

  /// `known`: voices heard before, each with a sample as a data URL. Only the diarizing model takes them.
  func fields(
    model: String,
    language: String?,
    words: [String],
    known: [(name: String, reference: String)]
  ) -> [Field] {
    var fields = [Field(name: "model", value: model)]
    switch self {
    case .keywords:
      if let language { fields.append(Field(name: "languages[]", value: language)) }
      fields += words.map { Field(name: "keywords[]", value: $0) }
    case .prompted:
      if let language { fields.append(Field(name: "language", value: language)) }
      if !words.isEmpty { fields.append(Field(name: "prompt", value: Hints.prompt(words))) }
    case .diarizing:
      fields.append(Field(name: "response_format", value: "diarized_json"))
      // Required by the model for anything longer than 30 seconds.
      fields.append(Field(name: "chunking_strategy", value: "auto"))
      if let language { fields.append(Field(name: "language", value: language)) }
      // The two lists pair up by position: the first name is the voice in the first sample.
      fields += known.map { Field(name: "known_speaker_names[]", value: $0.name) }
      fields += known.map { Field(name: "known_speaker_references[]", value: $0.reference) }
    case .timed:
      fields.append(Field(name: "response_format", value: "verbose_json"))
      fields.append(Field(name: "timestamp_granularities[]", value: "segment"))
      if let language { fields.append(Field(name: "language", value: language)) }
      if !words.isEmpty { fields.append(Field(name: "prompt", value: Hints.prompt(words))) }
    }
    return fields
  }
}

/// The user's dictionary words, made safe to send as hints.
enum Hints {
  /// Whisper reads only about the last 224 tokens of a prompt, so a longer list would not help.
  static let longestPrompt = 600

  /// OpenAI names no limit for `keywords`. A hundred is far more than a model can make use of.
  static let mostWords = 100

  /// The first `mostWords` words, each on one line, without the characters the API rejects a
  /// request for (`<`, `>` and line breaks), and without repeats.
  static func words(_ vocabulary: [String]) -> [String] {
    var seen: Set<String> = []
    var words: [String] = []
    for entry in vocabulary {
      let parts = entry.unicodeScalars.split { scalar in
        scalar == "<" || scalar == ">" || CharacterSet.whitespacesAndNewlines.contains(scalar)
          || CharacterSet.controlCharacters.contains(scalar)
      }
      let word = parts.map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
      guard !word.isEmpty, word.count <= 80, seen.insert(word.lowercased()).inserted else { continue }
      words.append(word)
      if words.count == mostWords { break }
    }
    return words
  }

  /// The words as one line, for models that take free text. Words that do not fit are left out.
  static func prompt(_ words: [String]) -> String {
    var prompt = ""
    for word in words {
      let next = prompt.isEmpty ? word : prompt + ", " + word
      if next.count > longestPrompt { break }
      prompt = next
    }
    return prompt
  }
}

// MARK: - Reading the reply

private struct Reply {
  private var text: String
  private var language: String?
  private var pieces: [Piece] = []

  private struct Piece {
    var start: TimeInterval
    var end: TimeInterval
    /// As sent, with the space that joins it to the piece before.
    var text: String
    /// How sure the model is that nobody spoke, 0...1. Only Whisper says.
    var noSpeech: Double?
    /// Who spoke. Only the diarizing model says.
    var speaker: String?
  }

  init(_ data: Data) throws {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let text = json["text"] as? String
    else { throw SpacesError.invalidResponse("the transcript was missing") }
    self.text = text
    if let languages = json["languages"] as? [[String: Any]] {
      language = languages.first?["code"] as? String
    } else {
      language = json["language"] as? String
    }
    for item in json["segments"] as? [[String: Any]] ?? [] {
      guard let start = (item["start"] as? NSNumber)?.doubleValue,
        let end = (item["end"] as? NSNumber)?.doubleValue, let text = item["text"] as? String
      else { continue }
      // Times come straight from the server. Anything that is not a real moment in the
      // recording (negative, infinite, not a number) is pinned to one that is.
      let from = Reply.moment(start) ?? 0
      pieces.append(
        Piece(
          start: from,
          end: max(from, Reply.moment(end) ?? from),
          text: text,
          noSpeech: (item["no_speech_prob"] as? NSNumber)?.doubleValue,
          speaker: (item["speaker"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        )
      )
    }
  }

  /// A time from the server as seconds from the start of the file: never negative, and never
  /// past 100 hours (far longer than any file the API takes), so it is always safe to turn
  /// into whole seconds. `nil` when it is not a number at all.
  private static func moment(_ time: Double) -> TimeInterval? {
    time.isFinite ? min(max(0, time), 359_999) : nil
  }

  /// The reply with made-up pieces taken out and white space trimmed.
  func transcript(fallbackLanguage: String?) -> Transcript {
    var kept: [Transcript.Segment] = []
    var rebuilt = ""
    for piece in pieces {
      let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
      // Whisper's own rule of thumb: above 0.6 it believes the stretch held no speech.
      let silent = (piece.noSpeech ?? 0) > 0.6
      if Silence.isNoise(text) || (silent && Silence.isStockPhrase(text)) { continue }
      kept.append(
        Transcript.Segment(
          start: piece.start,
          end: max(piece.start, piece.end),
          text: text,
          speaker: piece.speaker
        )
      )
      rebuilt += piece.text
    }
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if pieces.contains(where: { $0.speaker != nil }) {
      // The diarizing model puts each speaker's label in front of their line in `text`.
      text = kept.map(\.text).joined(separator: " ")
    } else if kept.count < pieces.count {
      text = rebuilt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if Silence.isNoise(text) {
      text = ""
      kept = []
    }
    return Transcript(text: text, segments: kept, language: Reply.code(for: language) ?? fallbackLanguage)
  }

  /// Whisper names the language in English ("english"); the newer models give a code.
  private static func code(for language: String?) -> String? {
    guard let language = language?.trimmingCharacters(in: .whitespaces).lowercased(), !language.isEmpty
    else { return nil }
    if let known = SpokenLanguage.all.first(where: { $0.name.lowercased() == language }) { return known.code }
    return language.count <= 3 || language.contains("-") ? language : nil
  }
}

// MARK: - The upload

/// Writes the form the API expects (`multipart/form-data`) to a temporary file,
/// copying the audio in small pieces so a long recording is never held in memory.
enum Upload {
  static func size(of audio: URL) throws -> Int {
    guard let values = try? audio.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true, let size = values.fileSize
    else { throw SpacesError.notFound("The recording") }
    return size
  }

  static func write(fields: [(name: String, value: String)], audio: URL) throws -> (
    file: URL, contentType: String
  ) {
    let boundary = "open-spaces-\(UUID().uuidString)"
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-spaces-upload-\(UUID().uuidString)")
    do {
      guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
      let output = try FileHandle(forWritingTo: file)
      defer { try? output.close() }
      let input = try FileHandle(forReadingFrom: audio)
      defer { try? input.close() }

      var head = ""
      for field in fields {
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n"
        head += field.value.split(whereSeparator: \.isNewline).joined(separator: " ") + "\r\n"
      }
      // The server tells the format from the file name's ending and the content type. The
      // real file name stays on this device.
      let ending = audio.pathExtension.lowercased()
      let name =
        ending.isEmpty || !ending.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        ? "audio" : "audio.\(ending)"
      head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n"
      head += "Content-Type: \(contentType(ending))\r\n\r\n"
      try output.write(contentsOf: Data(head.utf8))
      while let piece = try input.read(upToCount: 1 << 20), !piece.isEmpty {
        try output.write(contentsOf: piece)
      }
      try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw SpacesError.storage("the recording could not be read")
    }
    return (file, "multipart/form-data; boundary=\(boundary)")
  }

  private static func contentType(_ ending: String) -> String {
    switch ending {
    case "m4a": "audio/m4a"
    case "mp4": "audio/mp4"
    case "mp3", "mpga", "mpeg": "audio/mpeg"
    case "wav": "audio/wav"
    case "flac": "audio/flac"
    case "ogg", "oga": "audio/ogg"
    case "webm": "audio/webm"
    default: "application/octet-stream"
    }
  }
}

// MARK: - A known voice

/// A sample of a known voice the way the diarizing model takes it: a WAV file in a data URL.
enum VoiceSample {
  /// The stretch of audio the sample names, at most `Voices.sampleLength.upperBound` seconds of
  /// it, as 16-bit mono WAV in a `data:audio/wav;base64,` URL. A few hundred KB.
  static func dataURL(_ sample: Voices.Sample) throws -> String {
    let unreadable = SpacesError.storage("the recording could not be read")
    guard let file = try? AVAudioFile(forReading: sample.audio) else { throw unreadable }
    let format = file.processingFormat
    let rate = format.sampleRate
    let channels = Int(format.channelCount)
    let seconds = min(sample.end - sample.start, Voices.sampleLength.upperBound)
    guard rate > 0, channels > 0, sample.start.isFinite, seconds.isFinite, seconds > 0 else {
      throw unreadable
    }
    let first = AVAudioFramePosition(max(0, sample.start) * rate)
    let wanted = min(Double(file.length - first), seconds * rate)
    guard first < file.length, wanted >= 1,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wanted))
    else { throw unreadable }
    file.framePosition = first
    guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(wanted))) != nil,
      let samples = buffer.floatChannelData
    else { throw unreadable }

    let frames = Int(buffer.frameLength)
    var wav = Data(capacity: 44 + frames * 2)
    func append<Number: FixedWidthInteger>(_ number: Number) {
      withUnsafeBytes(of: number.littleEndian) { wav.append(contentsOf: $0) }
    }
    wav.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + frames * 2))
    wav.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))  // Plain PCM.
    append(UInt16(1))  // One channel.
    append(UInt32(rate))
    append(UInt32(rate) * 2)  // Bytes a second.
    append(UInt16(2))  // Bytes a frame.
    append(UInt16(16))  // Bits a sample.
    wav.append(contentsOf: Array("data".utf8))
    append(UInt32(frames * 2))
    for frame in 0..<frames {
      var sum: Float = 0
      for channel in 0..<channels { sum += samples[channel][frame] }
      let mixed = sum / Float(channels)
      let level = mixed.isFinite ? max(-1, min(1, mixed)) : 0
      append(Int16(level * Float(Int16.max)))
    }
    return "data:audio/wav;base64," + wav.base64EncodedString()
  }
}
