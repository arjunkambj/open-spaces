import AVFoundation
import Foundation

/// Tells real speech from text a transcription model made up.
///
/// Given silence, these models do not always return nothing. They were trained
/// on subtitled video, so they tend to write what such videos end with: a
/// subtitle credit, "Thanks for watching!", or just "Thank you." or "you".
///
/// What is done about it, from surest to least sure:
///
/// 1. **Never speech** (`isNoise`). Sound labels such as `[BLANK_AUDIO]` or `♪`, and the exact
///    subtitle credits these models are known for. Nobody dictates these, so they are removed
///    wherever they appear as a whole transcript or a whole timed piece.
/// 2. **The hint list read back** (`isEcho`). With nothing to hear, a model may return the
///    hint words it was given. A transcript that is exactly that list is treated as silence.
/// 3. **Stock phrases** (`isStockPhrase`). "Thank you." is also something people really say,
///    so it is removed only with proof that nobody spoke: Whisper's own no-speech score for
///    that piece, or a recording that is quiet from start to end (`isQuiet`).
///
/// What is *not* handled: a stock phrase made up over noise that is not speech (typing, a fan,
/// music). Nothing here can tell that from a person saying the phrase, so it is kept.
/// A stock phrase inside a longer transcript is always kept too.
enum Silence {
  /// Text that is never speech: empty, only symbols, only sound labels, or a subtitle credit.
  static func isNoise(_ text: String) -> Bool {
    let plain = normalize(text)
    if plain.isEmpty { return true }
    // "[BLANK_AUDIO]", "[Music] [Applause]", "*sighs*": speech is never written like this.
    let labels = #"^\s*(?:(?:\[[^\[\]]{1,40}\]|\*[^*]{1,40}\*)[\s.♪]*)+$"#
    if text.range(of: labels, options: .regularExpression) != nil { return true }
    // "(silence)", "(music)": round brackets can hold real words, so only known labels count.
    if text.range(of: #"^\s*[(（][^()（）]{1,40}[)）]\s*$"#, options: .regularExpression) != nil,
      soundLabels.contains(plain)
    {
      return true
    }
    return plain.count <= 120 && credits.contains(where: plain.hasPrefix)
  }

  /// Real words that models are also known to make up over silence. Matches the whole text only.
  static func isStockPhrase(_ text: String) -> Bool {
    stockPhrases.contains(normalize(text))
  }

  /// Whether `text` is just the hint words read back. Needs two or more words, because one
  /// word on its own ("Kubernetes") is something a person might well dictate.
  static func isEcho(_ text: String, of words: [String]) -> Bool {
    guard words.count >= 2 else { return false }
    let plain = normalize(text)
    return !plain.isEmpty && plain == normalize(words.joined(separator: " "))
  }

  /// Whether the recording is quiet from start to end: no tenth of a second louder than
  /// -50 dBFS. A quiet room sits below that and a soft voice well above it, so a low murmur
  /// still counts as sound.
  /// `nil` when the file cannot be read as audio; that counts as no proof.
  static func isQuiet(_ audio: URL) -> Bool? {
    guard let file = try? AVAudioFile(forReading: audio) else { return nil }
    let format = file.processingFormat
    let window = AVAudioFrameCount(max(1, format.sampleRate / 10))
    guard format.channelCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window)
    else { return nil }
    let loudest: Float = 0.00316  // -50 dBFS
    while file.framePosition < file.length {
      guard (try? file.read(into: buffer, frameCount: window)) != nil, buffer.frameLength > 0,
        let channels = buffer.floatChannelData
      else { return nil }
      for channel in 0..<Int(format.channelCount) {
        let samples = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
        let energy = samples.reduce(Float(0)) { $0 + $1 * $1 }
        if (energy / Float(samples.count)).squareRoot() > loudest { return false }
      }
    }
    return true
  }

  /// Lower case, no accents, letters and digits only, single spaces.
  static func normalize(_ text: String) -> String {
    let folded = text.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: nil
    )
    let words = folded.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }
    return words.map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
  }

  private static let soundLabels: Set<String> = Set(
    [
      "silence", "blank audio", "no audio", "no speech", "inaudible", "music", "music playing", "applause",
      "laughter", "noise", "background noise", "sound", "static", "silencio", "musica", "musique", "musik",
      "音楽", "拍手", "音乐", "无声",
    ].map(normalize)
  )

  /// Starts of the subtitle credits these models are known to write, each specific enough that
  /// no one says it by accident. Compared after `normalize`.
  private static let credits: [String] = [
    "Subtitles by the Amara.org community", "Transcribed by https://otter.ai",
    "Untertitel im Auftrag des ZDF", "Untertitelung des ZDF", "Untertitel der Amara.org-Community",
    "Sous-titres réalisés par la communauté d'Amara.org", "Sous-titrage ST' 501",
    "Sous-titrage Société Radio-Canada", "Sottotitoli e revisione a cura di QTSS",
    "Sottotitoli creati dalla comunità Amara.org", "Subtítulos realizados por la comunidad de Amara.org",
    "Legendas pela comunidade Amara.org", "Ondertitels ingediend door de Amara.org gemeenschap",
    "Napisy stworzone przez społeczność Amara.org", "Субтитры сделал DimaTorzok",
    "Субтитры создавал DimaTorzok", "Редактор субтитров", "字幕由Amara.org社区提供", "字幕by",
    "请不吝点赞",
  ].map(normalize)

  /// Whole transcripts that are as likely made up as said. Compared after `normalize`.
  private static let stockPhrases: Set<String> = Set(
    [
      "you", "thank you", "thank you very much", "thank you so much", "thanks", "thank you for watching",
      "thanks for watching", "thank you so much for watching", "thanks for watching and see you next time",
      "bye", "bye bye", "goodbye", "see you next time", "see you in the next video", "please subscribe",
      "ご視聴ありがとうございました", "ありがとうございました", "おやすみなさい", "시청해주셔서 감사합니다",
      "감사합니다", "谢谢观看", "謝謝觀看", "谢谢大家", "謝謝大家", "谢谢", "謝謝", "продолжение следует",
      "спасибо за просмотр", "спасибо", "gracias por ver el video", "gracias por ver", "gracias",
      "merci d avoir regarde cette video", "merci", "vielen dank furs zuschauen", "vielen dank",
      "obrigado por assistir", "obrigado", "grazie per la visione", "grazie a tutti", "grazie",
      "bedankt voor het kijken", "bedankt", "dziekuje za uwage", "dziekuje", "tesekkur ederim",
    ].map(normalize)
  )
}
