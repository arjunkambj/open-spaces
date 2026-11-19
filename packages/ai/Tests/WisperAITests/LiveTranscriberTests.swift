import Foundation
import Testing
import WisperDomain

@testable import WisperAI

/// Transcription while speaking, against a small local server that speaks the realtime protocol
/// as OpenAI documents it.
@Suite(.timeLimit(.minutes(1)))
struct LiveTranscriberTests {
  /// A server that behaves well: takes the settings, and answers a commit with `text`.
  static func server(
    hears text: String = "Hello there.",
    deltas: [String] = [],
    languages: [String]? = nil
  ) throws -> SocketServer {
    try SocketServer { message, peer in
      switch message["type"] as? String {
      case "session.update":
        peer.say(["type": "session.updated", "session": ["type": "transcription"]])
      case "input_audio_buffer.commit":
        peer.say(["type": "input_audio_buffer.committed", "item_id": "item_1"])
        for delta in deltas {
          peer.say([
            "type": "conversation.item.input_audio_transcription.delta", "item_id": "item_1", "delta": delta,
          ])
        }
        var done: [String: Any] = [
          "type": "conversation.item.input_audio_transcription.completed", "item_id": "item_1",
          "transcript": text,
        ]
        if let languages { done["languages"] = languages.map { ["code": $0] } }
        peer.say(done)
      default:
        break
      }
    }
  }

  static func openAI(_ server: SocketServer, key: String? = "sk-local", savedFor host: String = "127.0.0.1")
    -> OpenAI
  {
    OpenAI(
      secrets: InMemorySecretStore(apiKey: key, host: host),
      address: { server.address },
      connections: Connections(watchesNetwork: false)
    ) { _ in }
  }

  static func tone(_ seconds: Double, rate: Double = 16_000) -> AudioFrames {
    AudioFrames(
      samples: (0..<Int(seconds * rate)).map { 0.25 * sin(Float($0) * 2 * .pi * 440 / Float(rate)) },
      sampleRate: rate
    )
  }

  // MARK: The protocol

  @Test func streamsTheSoundAndReturnsTheTextOfTheCommit() async throws {
    let server = try Self.server(hears: " Could we move the review to Thursday? ")
    let live = Self.openAI(server).liveTranscriber

    let session = try await live.open(
      LiveTranscriptionRequest(
        model: "gpt-live-transcribe",
        language: "en",
        vocabulary: ["Priya Raman", "<b>"]
      )
    )
    // Half a second, in ten pieces, as a microphone would hand it over.
    for _ in 0..<10 { session.send(Self.tone(0.05)) }
    let transcript = try await session.finish()

    #expect(transcript.text == "Could we move the review to Thursday?")
    #expect(transcript.language == "en")

    // The handshake: the realtime endpoint under the API folder, for transcription, with the key.
    #expect(server.requestLines == ["GET /v1/realtime?intent=transcription HTTP/1.1"])
    #expect(server.handshakes.first?["authorization"] == "Bearer sk-local")

    // Settings first, then the sound, then one commit.
    #expect(server.types.first == "session.update")
    #expect(server.types.last == "input_audio_buffer.commit")
    #expect(server.types.filter { $0 == "input_audio_buffer.commit" }.count == 1)
    #expect(server.types.dropFirst().dropLast().allSatisfy { $0 == "input_audio_buffer.append" })

    let setup = try #require(server.events.first?["session"] as? [String: Any])
    #expect(setup["type"] as? String == "transcription")
    let input = try #require((setup["audio"] as? [String: Any])?["input"] as? [String: Any])
    #expect(input["format"] as? [String: AnyHashable] == ["type": "audio/pcm", "rate": 24_000])
    // The app decides where the recording ends, not the server.
    #expect(input["turn_detection"] is NSNull)
    let asked = try #require(input["transcription"] as? [String: Any])
    #expect(asked["model"] as? String == "gpt-live-transcribe")
    #expect(asked["languages"] as? [String] == ["en"])
    // Hints are cleaned the same way as for a file.
    #expect(asked["keywords"] as? [String] == ["Priya Raman", "b"])
  }

  @Test func theSoundArrivesWholeAt24kHz() async throws {
    let server = try Self.server()
    let session = try await Self.openAI(server).liveTranscriber.open(
      LiveTranscriptionRequest(model: "gpt-live-transcribe")
    )

    for _ in 0..<20 { session.send(Self.tone(0.1)) }
    _ = try await session.finish()

    let sound = server.sound
    // Two seconds at 16 kHz went in: two seconds at 24 kHz came out, to within a sample or two.
    #expect(abs(sound.count - 48_000) <= 2)
    // Still the same tone at a quarter of full volume: RMS about 0.177 of 32,767.
    let rms = (sound.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(sound.count)).squareRoot()
    #expect(abs(rms / 32_767 - 0.1768) < 0.01)
    // No click where one piece ends and the next begins: neighbours never jump.
    let biggestStep = zip(sound, sound.dropFirst()).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(biggestStep < 1_200, "a step of \(biggestStep)")
  }

  @Test func reportsWhatWasHeardSoFar() async throws {
    let server = try Self.server(hears: "Hello there, world.", deltas: ["Hello", " there,", " world."])
    let session = try await Self.openAI(server).liveTranscriber.open(
      LiveTranscriptionRequest(model: "gpt-live-transcribe")
    )
    session.send(Self.tone(0.3))

    let listening = Task { () -> [String] in
      var all: [String] = []
      for await partial in session.partials { all.append(partial) }
      return all
    }
    let transcript = try await session.finish()
    let partials = await listening.value

    #expect(transcript.text == "Hello there, world.")
    // Each value replaces the one before, and the stream ends with the session.
    #expect(partials.last == "Hello there, world.")
    #expect(partials.allSatisfy { "Hello there, world.".hasPrefix($0) })
  }

  @Test func readsTheLanguageTheModelDetected() async throws {
    let server = try Self.server(hears: "Bonjour.", languages: ["fr"])
    let session = try await Self.openAI(server).liveTranscriber.open(
      LiveTranscriptionRequest(model: "gpt-live-transcribe")
    )
    session.send(Self.tone(0.3))

    #expect(try await session.finish().language == "fr")
  }

  @Test func soundsWrittenOutAsWordsAreSilence() async throws {
    let server = try Self.server(hears: "[BLANK_AUDIO]")
    let session = try await Self.openAI(server).liveTranscriber.open(
      LiveTranscriptionRequest(model: "gpt-live-transcribe")
    )
    session.send(Self.tone(0.3))

    #expect(try await session.finish().text.isEmpty)
  }

  // MARK: When it cannot be done

  @Test(arguments: ["gpt-transcribe", "whisper-1", "gpt-4o-transcribe", "whisper-large-v3", ""])
  func aModelThatCannotTranscribeLiveIsRefusedBeforeAnythingIsSent(model: String) async throws {
    let server = try Self.server()
    let live = Self.openAI(server).liveTranscriber

    let error = await wisperError { _ = try await live.open(LiveTranscriptionRequest(model: model)) }

    #expect(error == Realtime.unavailable)
    #expect(server.handshakes.isEmpty)
  }

  @Test func aServerWithoutTheRealtimeAPIMakesOpenFail() async throws {
    let server = try SocketServer(accepts: false) { _, _ in }

    let error = await wisperError {
      _ = try await Self.openAI(server).liveTranscriber.open(
        LiveTranscriptionRequest(model: "gpt-live-transcribe")
      )
    }

    #expect(error == Realtime.unavailable)
  }

  @Test func settingsTheServerRefusesMakeOpenFail() async throws {
    let server = try SocketServer { message, peer in
      if message["type"] as? String == "session.update" {
        peer.say(["type": "error", "error": ["message": "Unsupported language code."]])
      }
    }

    let error = await wisperError {
      _ = try await Self.openAI(server).liveTranscriber.open(
        LiveTranscriptionRequest(model: "gpt-live-transcribe")
      )
    }

    #expect(error == Realtime.unavailable)
  }

  @Test func aConnectionThatDropsHalfWayMakesFinishFail() async throws {
    let server = try SocketServer { message, peer in
      switch message["type"] as? String {
      case "session.update": peer.say(["type": "session.updated"])
      case "input_audio_buffer.append": peer.hangUp()
      default: break
      }
    }
    let session = try await Self.openAI(server).liveTranscriber.open(
      LiveTranscriptionRequest(model: "gpt-live-transcribe")
    )
    session.send(Self.tone(0.3))

    let error = await wisperError { _ = try await session.finish() }

    #expect(error == Realtime.unavailable)
  }

  @Test func aTranscriptionTheServerFailsMakesFinishFail() async throws {
    let server = try SocketServer { message, peer in
      switch message["type"] as? String {
      case "session.update":
        peer.say(["type": "session.updated"])
      case "input_audio_buffer.commit":
        peer.say(["type": "input_audio_buffer.committed", "item_id": "item_1"])
        peer.say(["type": "conversation.item.input_audio_transcription.failed", "item_id": "item_1"])
      default:
        break
      }
    }
    let session = try await Self.openAI(server).liveTranscriber.open(
      LiveTranscriptionRequest(model: "gpt-live-transcribe")
    )
    session.send(Self.tone(0.3))

    let error = await wisperError { _ = try await session.finish() }

    #expect(error == Realtime.unavailable)
  }

  @Test func theTextOfAnotherItemIsNotTakenForOurs() async throws {
    let server = try SocketServer { message, peer in
      switch message["type"] as? String {
      case "session.update":
        peer.say(["type": "session.updated"])
      case "input_audio_buffer.commit":
        // Something else finishes first. Ours is `item_2`.
        peer.say([
          "type": "conversation.item.input_audio_transcription.completed", "item_id": "item_1",
          "transcript": "Not this.",
        ])
        peer.say(["type": "input_audio_buffer.committed", "item_id": "item_2"])
        peer.say([
          "type": "conversation.item.input_audio_transcription.completed", "item_id": "item_2",
          "transcript": "This one.",
        ])
      default:
        break
      }
    }
    let session = try await Self.openAI(server).liveTranscriber.open(
      LiveTranscriptionRequest(model: "gpt-live-transcribe")
    )
    session.send(Self.tone(0.3))

    #expect(try await session.finish().text == "This one.")
  }

  @Test func cancellingEndsAFinishThatIsWaiting() async throws {
    // Takes the commit and then never says anything.
    let server = try SocketServer { message, peer in
      if message["type"] as? String == "session.update" { peer.say(["type": "session.updated"]) }
    }
    let session = try await Self.openAI(server).liveTranscriber.open(
      LiveTranscriptionRequest(model: "gpt-live-transcribe")
    )
    session.send(Self.tone(0.3))

    let finishing = Task { try await session.finish() }
    for _ in 0..<400 where !server.types.contains("input_audio_buffer.commit") {
      try await Task.sleep(for: .milliseconds(5))
    }
    session.cancel()

    await #expect(throws: WisperError.self) { _ = try await finishing.value }
  }

  // MARK: Where the key and the sound may go

  @Test func aKeySavedForAnotherServerIsNotSent() async throws {
    let server = try Self.server()
    // The key belongs to OpenAI. The settings name a server on this machine.
    let live = Self.openAI(server, savedFor: APIServer.openAIHost).liveTranscriber

    let session = try await live.open(LiveTranscriptionRequest(model: "gpt-live-transcribe"))
    session.cancel()

    #expect(server.handshakes.count == 1)
    #expect(server.handshakes.first?["authorization"] == nil)
  }

  @Test func nothingIsOpenedWhenARequestCouldNotBeSentEither() async throws {
    let server = try Self.server()
    let noKey = OpenAI(
      secrets: InMemorySecretStore(apiKey: nil),
      address: { nil },
      connections: Connections(watchesNetwork: false)
    ) { _ in }
    let badAddress = OpenAI(
      secrets: InMemorySecretStore(apiKey: "sk-test-key"),
      address: { "127.0.0.1:\(server.port)/v1" },
      connections: Connections(watchesNetwork: false)
    ) { _ in }
    let request = LiveTranscriptionRequest(model: "gpt-live-transcribe")

    #expect(await wisperError { _ = try await noKey.liveTranscriber.open(request) } == .missingAPIKey)
    #expect(
      await wisperError { _ = try await badAddress.liveTranscriber.open(request) } == .invalidServerAddress
    )
    #expect(server.handshakes.isEmpty)
  }

  // MARK: The live model and files

  @Test func aFileGoesToTheSiblingModelWhenTheChosenOneOnlyWorksLive() async throws {
    let server = Server(.ok(#"{"text": "Hi."}"#))
    let recordings = try Recordings()

    for (chosen, sent) in [
      ("gpt-live-transcribe", "gpt-transcribe"), ("openai/gpt-live-transcribe", "openai/gpt-transcribe"),
      ("gpt-transcribe", "gpt-transcribe"), ("whisper-1", "whisper-1"),
    ] {
      _ = try await server.openAI().transcriber.transcribe(
        TranscriptionRequest(audio: try recordings.file(), model: chosen, vocabulary: ["Acme"])
      )
      let form = try #require(server.requests.last).form
      #expect(form.value("model") == sent)
    }
    // Asked the way its sibling is asked: words as keywords.
    #expect(server.requests[0].form.values("keywords[]") == ["Acme"])
  }

  // MARK: Changing the rate

  @Test func piecesOfAnyLengthJoinWithoutLosingOrAddingSound() {
    var whole = Upsampler(to: 24_000)
    var pieces = Upsampler(to: 24_000)
    let sound = Self.tone(1).samples

    let atOnce = whole.convert(AudioFrames(samples: sound, sampleRate: 16_000))
    var joined = Data()
    var start = 0
    for length in [1, 7, 160, 333, 800, 1_601, 5_000, 16_000] where start < sound.count {
      let end = min(start + length, sound.count)
      joined += pieces.convert(AudioFrames(samples: Array(sound[start..<end]), sampleRate: 16_000))
      start = end
    }
    joined += pieces.convert(AudioFrames(samples: Array(sound[start...]), sampleRate: 16_000))

    // A second at 16 kHz is a second at 24 kHz, two bytes a sample. (The very last sample waits
    // for the sound that would follow it.)
    #expect(abs(atOnce.count / 2 - 24_000) <= 1)
    #expect(joined == atOnce)
  }
}
