import Foundation
import Testing
import WisperDomain

@testable import WisperAI

@Suite struct TranscriberTests {
  let recordings: Recordings

  init() throws { recordings = try Recordings() }

  // MARK: Request shape

  @Test func uploadsTheAudioWithKeywordsForTheCurrentModel() async throws {
    let server = Server(.ok(#"{"text": "  Deploy it to Kubernetes. \n", "languages": [{"code": "en"}]}"#))
    let audio = try recordings.file("My private note.m4a", bytes: Data([0, 1, 2, 253, 254, 255]))

    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(
        audio: audio,
        model: "gpt-transcribe",
        language: "en",
        vocabulary: ["Kubernetes", "Priya Raman"]
      )
    )

    #expect(transcript == Transcript(text: "Deploy it to Kubernetes.", language: "en"))
    let request = try #require(server.requests.first)
    #expect(server.requests.count == 1)
    #expect(request.method == "POST")
    #expect(request.url.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
    #expect(request.header("Authorization") == "Bearer sk-test-key")
    #expect(request.header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    let form = request.form
    #expect(form.names == ["model", "languages[]", "keywords[]", "keywords[]", "file"])
    #expect(form.value("model") == "gpt-transcribe")
    #expect(form.values("languages[]") == ["en"])
    #expect(form.values("keywords[]") == ["Kubernetes", "Priya Raman"])
    #expect(form.file?.data == Data([0, 1, 2, 253, 254, 255]))
    #expect(form.file?.contentType == "audio/m4a")
    // The format is told from the ending. The file's own name stays on the device.
    #expect(form.file?.fileName == "audio.m4a")
  }

  @Test func asksWhisperForTimedPieces() async throws {
    let server = Server(
      .ok(
        """
        {"task": "transcribe", "language": "english", "duration": 6.1, "text": " Hello there. How are you?",
         "segments": [
           {"id": 0, "start": 0.0, "end": 2.5, "text": " Hello there.", "no_speech_prob": 0.01},
           {"id": 1, "start": 2.5, "end": 6.1, "text": " How are you?", "no_speech_prob": 0.02}]}
        """
      )
    )

    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(
        audio: try recordings.file("clip.wav"),
        model: "whisper-1",
        language: "en",
        vocabulary: ["Kubernetes", "PostgreSQL"]
      )
    )

    #expect(transcript.text == "Hello there. How are you?")
    #expect(
      transcript.segments == [
        Transcript.Segment(start: 0, end: 2.5, text: "Hello there."),
        Transcript.Segment(start: 2.5, end: 6.1, text: "How are you?"),
      ]
    )
    #expect(transcript.language == "en")
    let form = try #require(server.requests.first).form
    #expect(form.value("model") == "whisper-1")
    #expect(form.value("response_format") == "verbose_json")
    #expect(form.values("timestamp_granularities[]") == ["segment"])
    #expect(form.value("language") == "en")
    #expect(form.value("prompt") == "Kubernetes, PostgreSQL")
    #expect(form.file?.contentType == "audio/wav")
    #expect(form.file?.fileName == "audio.wav")
  }

  @Test func sendsWordsAsAPromptToTheOlderModels() async throws {
    let server = Server(.ok(#"{"text": "Hola."}"#))

    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(
        audio: try recordings.file(),
        model: "gpt-4o-mini-transcribe",
        language: "es",
        vocabulary: ["Open Wisper"]
      )
    )

    // These models give no timestamps and name no language, so the one asked for is passed on.
    #expect(transcript == Transcript(text: "Hola.", language: "es"))
    let form = try #require(server.requests.first).form
    #expect(form.names == ["model", "language", "prompt", "file"])
    #expect(form.value("prompt") == "Open Wisper")
  }

  @Test func readsTimedPiecesFromTheSpeakerLabellingModel() async throws {
    let server = Server(
      .ok(
        """
        {"task": "transcribe", "duration": 9, "text": "Hi. Hello.", "segments": [
          {"type": "transcript.text.segment", "id": "seg_1", "start": 0, "end": 4, "text": "Hi.", "speaker": "A"},
          {"type": "transcript.text.segment", "id": "seg_2", "start": 4.5, "end": 9, "text": "Hello.",
           "speaker": "B"}]}
        """
      )
    )

    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(
        audio: try recordings.file(),
        model: "gpt-4o-transcribe-diarize",
        vocabulary: ["Kubernetes"]
      )
    )

    #expect(transcript.segments.map(\.start) == [0, 4.5])
    #expect(transcript.segments.map(\.text) == ["Hi.", "Hello."])
    let form = try #require(server.requests.first).form
    #expect(form.names == ["model", "response_format", "chunking_strategy", "file"])
    #expect(form.value("response_format") == "diarized_json")
    #expect(form.value("chunking_strategy") == "auto")
  }

  @Test func sendsNorwegianUnderTheCodeTheModelsKnow() async throws {
    let server = Server(.ok(#"{"text": "Hei.", "language": "norwegian"}"#))

    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.file(), model: "whisper-1", language: "nb")
    )

    #expect(try #require(server.requests.first).form.value("language") == "no")
    // What comes back uses the app's own code again.
    #expect(transcript.language == "nb")
  }

  @Test func leavesHintsOutWhenThereAreNone() async throws {
    let server = Server(.ok(#"{"text": "Hi."}"#))

    _ = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.file(), model: "gpt-transcribe", vocabulary: ["", "  "])
    )

    #expect(try #require(server.requests.first).form.names == ["model", "file"])
  }

  @Test func cleansWordsThatWouldBreakTheRequest() async throws {
    let server = Server(.ok(#"{"text": "Hi."}"#))

    _ = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(
        audio: try recordings.file(),
        model: "gpt-transcribe",
        vocabulary: ["  Priya\nRaman ", "<b>Acme</b>", "priya raman", String(repeating: "x", count: 200)]
      )
    )

    // One line each, no angle brackets, no repeats, nothing absurdly long.
    #expect(try #require(server.requests.first).form.values("keywords[]") == ["Priya Raman", "b Acme /b"])
  }

  @Test func givesShortAudioAShortWaitAndLongAudioALongOne() async throws {
    let server = Server(.ok(#"{"text": "Hi."}"#))
    let transcriber = server.openAI().transcriber

    _ = try await transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.file("short.m4a"), model: "gpt-transcribe")
    )
    let long = try recordings.file("long.m4a", bytes: Data(count: 4 * 1_024 * 1_024))
    _ = try await transcriber.transcribe(TranscriptionRequest(audio: long, model: "gpt-transcribe"))

    #expect(server.requests[0].timeout == 20)
    // More than the 60 seconds a request gets by default, so a few megabytes on a slow link get through.
    #expect(server.requests[1].timeout > 100)
  }

  // MARK: Hints the server refuses

  @Test func sendsAgainWithoutAHintTheServerRefuses() async throws {
    let server = Server { request, _ in
      request.form.names.contains("languages[]")
        ? .error(400, "Invalid language 'xx'.", param: "languages[0]", code: "invalid_value")
        : .ok(#"{"text": "Hello."}"#)
    }
    let transcriber = server.openAI().transcriber
    let request = TranscriptionRequest(
      audio: try recordings.file(),
      model: "gpt-transcribe",
      language: "xx",
      vocabulary: ["Kubernetes"]
    )

    #expect(try await transcriber.transcribe(request).text == "Hello.")
    #expect(
      server.requests.map(\.form.names) == [
        ["model", "languages[]", "keywords[]", "file"], ["model", "keywords[]", "file"],
      ]
    )

    // The refusal is remembered, so the next dictation does not upload its audio twice.
    #expect(try await transcriber.transcribe(request).text == "Hello.")
    #expect(server.requests.count == 3)
    #expect(server.requests[2].form.names == ["model", "keywords[]", "file"])
  }

  @Test func fallsBackToPlainTextWhenAServerHasNoTimedFormat() async throws {
    let server = Server { request, _ in
      request.form.value("response_format") == nil
        ? .ok(#"{"text": "Hello."}"#)
        : .reply(status: 400, body: #"{"detail": "response_format verbose_json is not supported"}"#)
    }

    let transcript = try await server.openAI(baseURL: "http://localhost:8000").transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.file(), model: "whisper-large-v3")
    )

    #expect(transcript == Transcript(text: "Hello."))
    #expect(
      server.requests.map(\.form.names) == [
        ["model", "response_format", "timestamp_granularities[]", "file"], ["model", "file"],
      ]
    )
  }

  // MARK: Silence

  @Test(arguments: ["", "   \n", "[BLANK_AUDIO]", "[Music]", "(silence)", "♪♪", "...", "*sighs*"])
  func returnsNoTextForAReplyThatIsNotSpeech(reply: String) async throws {
    let body = try JSONSerialization.data(withJSONObject: ["text": reply])
    let server = Server(.ok(String(decoding: body, as: UTF8.self)))

    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.file(), model: "gpt-transcribe")
    )

    #expect(transcript.text == "")
    #expect(transcript.segments.isEmpty)
  }

  @Test(arguments: [
    "Subtitles by the Amara.org community", "Untertitel im Auftrag des ZDF, 2020",
    "Sous-titres réalisés par la communauté d'Amara.org", "Transcribed by https://otter.ai",
  ])
  func dropsSubtitleCreditsNobodySays(credit: String) async throws {
    let body = try JSONSerialization.data(withJSONObject: ["text": credit])
    let server = Server(.ok(String(decoding: body, as: UTF8.self)))

    // The recording is loud here, to show these go whatever the audio holds.
    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.wav("loud.wav", level: 0.5), model: "gpt-transcribe")
    )

    #expect(transcript.text == "")
  }

  @Test(arguments: ["Thank you.", "you", "Thanks for watching!", "Bye.", "ご視聴ありがとうございました"])
  func dropsAStockPhraseOnlyWhenTheRecordingIsSilent(phrase: String) async throws {
    let body = try JSONSerialization.data(withJSONObject: ["text": phrase])
    let server = Server(.ok(String(decoding: body, as: UTF8.self)))
    let transcriber = server.openAI().transcriber

    let silent = try await transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.wav("silent.wav", level: 0), model: "gpt-transcribe")
    )
    let hiss = try await transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.wav("hiss.wav", level: 0.001), model: "gpt-transcribe")
    )
    let spoken = try await transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.wav("spoken.wav", level: 0.05), model: "gpt-transcribe")
    )
    // A file that cannot be measured gives no proof of silence, so the words stay.
    let unknown = try await transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.file("unknown.m4a"), model: "gpt-transcribe")
    )

    #expect(silent.text == "")
    #expect(hiss.text == "")
    #expect(spoken.text == phrase)
    #expect(unknown.text == phrase)
  }

  @Test func keepsStockPhrasesInsideRealSpeech() async throws {
    let server = Server(.ok(#"{"text": "Thank you. I will send the report tomorrow."}"#))

    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.wav("silent.wav", level: 0), model: "gpt-transcribe")
    )

    #expect(transcript.text == "Thank you. I will send the report tomorrow.")
  }

  @Test func dropsTimedPiecesWhisperItselfMarksAsSilent() async throws {
    let server = Server(
      .ok(
        """
        {"language": "english", "text": " Send the report tomorrow. Thank you. Thank you. [BLANK_AUDIO]",
         "segments": [
           {"start": 0, "end": 3, "text": " Send the report tomorrow.", "no_speech_prob": 0.02},
           {"start": 3, "end": 4, "text": " Thank you.", "no_speech_prob": 0.05},
           {"start": 4, "end": 29, "text": " Thank you.", "no_speech_prob": 0.93},
           {"start": 29, "end": 30, "text": " [BLANK_AUDIO]", "no_speech_prob": 0.4}]}
        """
      )
    )

    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.file(), model: "whisper-1")
    )

    // The "Thank you." that was really said stays; the one over silence goes.
    #expect(transcript.text == "Send the report tomorrow. Thank you.")
    #expect(transcript.segments.map(\.text) == ["Send the report tomorrow.", "Thank you."])
  }

  @Test func treatsTheHintListReadBackAsSilence() async throws {
    let server = Server(.ok(#"{"text": "Kubernetes, PostgreSQL."}"#))
    let transcriber = server.openAI().transcriber

    let echoed = try await transcriber.transcribe(
      TranscriptionRequest(
        audio: try recordings.file(),
        model: "gpt-4o-transcribe",
        vocabulary: ["Kubernetes", "PostgreSQL"]
      )
    )
    // One word on its own is something a person may well say.
    let single = try await transcriber.transcribe(
      TranscriptionRequest(
        audio: try recordings.file(),
        model: "gpt-4o-transcribe",
        vocabulary: ["Kubernetes, PostgreSQL."]
      )
    )

    #expect(echoed.text == "")
    #expect(single.text == "Kubernetes, PostgreSQL.")
  }

  // MARK: Before anything is sent

  @Test func returnsNoTextForAnEmptyFileWithoutAskingTheServer() async throws {
    let server = Server(.ok(#"{"text": "should not be asked"}"#))

    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.file("empty.m4a", bytes: Data()), model: "gpt-transcribe")
    )

    #expect(transcript.text == "")
    #expect(server.requests.isEmpty)
  }

  @Test func reportsAMissingRecording() async throws {
    let server = Server(.ok(#"{"text": "should not be asked"}"#))
    let missing = recordings.folder.appendingPathComponent("gone.m4a")

    let error = await wisperError {
      _ = try await server.openAI().transcriber.transcribe(
        TranscriptionRequest(audio: missing, model: "gpt-transcribe")
      )
    }

    #expect(error == .notFound("The recording"))
    #expect(server.requests.isEmpty)
  }

  @Test func turnsDownAFileOpenAIWouldRejectBeforeUploadingIt() async throws {
    let server = Server(.ok(#"{"text": "should not be asked"}"#))
    let huge = try recordings.file("huge.m4a", bytes: Data())
    let handle = try FileHandle(forWritingTo: huge)
    try handle.truncate(atOffset: 26 * 1_024 * 1_024)
    try handle.close()

    let error = await wisperError {
      _ = try await server.openAI().transcriber.transcribe(
        TranscriptionRequest(audio: huge, model: "gpt-transcribe")
      )
    }

    #expect(
      error == .server(status: 413, message: "This recording is 26 MB. OpenAI takes audio files up to 25 MB.")
    )
    #expect(server.requests.isEmpty)
  }

  @Test func rejectsAReplyWithNoTranscript() async throws {
    let server = Server(.ok(#"{"unexpected": true}"#))

    let error = await wisperError {
      _ = try await server.openAI().transcriber.transcribe(
        TranscriptionRequest(audio: try recordings.file(), model: "gpt-transcribe")
      )
    }

    #expect(error == .invalidResponse("the transcript was missing"))
  }

  @Test func timesFromTheServerAreMadeSafeBeforeUse() async throws {
    // Negative, absurdly large, and ending before they begin. None may reach a caller as they are.
    let server = Server(
      .ok(
        """
        {"language": "english", "text": " One. Two. Three. Four. Five.",
         "segments": [
           {"start": -5, "end": 2, "text": " One."},
           {"start": -1e300, "end": -3, "text": " Two."},
           {"start": 4, "end": -1e300, "text": " Three."},
           {"start": 6, "end": 1e300, "text": " Four."},
           {"start": 1e300, "end": 8, "text": " Five."}]}
        """
      )
    )

    let transcript = try await server.openAI().transcriber.transcribe(
      TranscriptionRequest(audio: try recordings.file(), model: "whisper-1")
    )

    #expect(transcript.segments.map(\.text) == ["One.", "Two.", "Three.", "Four.", "Five."])
    for segment in transcript.segments {
      #expect(segment.start.isFinite && segment.start >= 0, "\(segment)")
      #expect(segment.end.isFinite && segment.end >= segment.start, "\(segment)")
      // Safe to turn into whole seconds, which is what callers do with them.
      #expect(Int(exactly: segment.end.rounded()) != nil)
    }
    #expect(transcript.segments.map(\.start) == [0, 0, 4, 6, 359_999])
    #expect(transcript.segments.map(\.end) == [2, 0, 4, 359_999, 359_999])
  }
}
