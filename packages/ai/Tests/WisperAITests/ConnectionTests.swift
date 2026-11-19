import Foundation
import Testing
import WisperDomain

@testable import WisperAI

/// What happens when a request gets no answer, and which connection the next one uses.
@Suite struct ConnectionTests {
  static let hello = LanguageModelTests.reply("Hello.")
  static let helloBody = #"{"choices": [{"message": {"role": "assistant", "content": "Hello."}}]}"#
  static let prompt = CompletionRequest(model: "m", system: "", user: "hi")
  let recordings: Recordings

  init() throws { recordings = try Recordings() }

  /// A client that keeps real sessions of its own and talks to `server`.
  static func client(
    _ server: QuietServer,
    connections: Connections = Connections(watchesNetwork: false)
  ) -> Client {
    Client(
      secrets: InMemorySecretStore(apiKey: "sk-local", host: "127.0.0.1"),
      address: { server.address },
      connections: connections
    ) { _ in }
  }

  static func seconds(_ work: () async throws -> Void) async rethrows -> TimeInterval {
    let start = ContinuousClock.now
    try await work()
    let taken = ContinuousClock.now - start
    return Double(taken.components.seconds) + Double(taken.components.attoseconds) / 1e18
  }

  // MARK: A request that gets no answer

  @Test func aSilentTryIsSentAgainAtOnce() async throws {
    let server = Server(.fail(.timedOut), Self.hello)

    let text = try await server.openAI().languageModel.complete(Self.prompt)

    #expect(text == "Hello.")
    #expect(server.requests.count == 2)
    // The waiting was done already: no pause on top.
    #expect(server.pauses.isEmpty)
  }

  @Test func twoSilentTriesAreEnough() async throws {
    let server = Server(.fail(.timedOut))

    let error = await wisperError { _ = try await server.openAI().languageModel.complete(Self.prompt) }

    #expect(error == .noAnswer)
    #expect(server.requests.count == 2)
    #expect(
      error?.errorDescription == "OpenAI did not answer in time, even on a second try. Try again in a moment."
    )
  }

  @Test func aStalledConnectionIsGivenUpQuicklyAndTheRetryUsesANewOne() async throws {
    // The first connection takes the request and then says nothing, like one that died quietly.
    let server = try QuietServer { seen in seen.connection == 1 ? .silence : QuietServer.ok(Self.helloBody) }
    let connections = Connections(watchesNetwork: false)
    let client = Self.client(server, connections: connections)
    var reply = Data()

    let taken = try await Self.seconds {
      reply = try await client.send(budget: 20) { _ in
        Client.Call(method: "POST", path: "chat/completions", body: .json(Data("{}".utf8)), wait: 1)
      }
    }

    #expect(String(decoding: reply, as: UTF8.self) == Self.helloBody)
    // One second of silence was enough. The answer did not have to wait for the whole allowance.
    #expect((0.9...3).contains(taken), "took \(taken) s")
    // The same request went out twice, the second time on a connection of its own…
    #expect(server.requests.map(\.connection) == [1, 2])
    #expect(server.requests.map(\.request.body) == [Data("{}".utf8), Data("{}".utf8)])
    // …that belongs to a new session, so nothing of the old one could be used again.
    #expect(connections.sessionsMade == 2)
  }

  @Test func theRequestAfterAStallStartsOnTheNewConnectionToo() async throws {
    let server = try QuietServer { seen in seen.connection == 1 ? .silence : QuietServer.ok(Self.helloBody) }
    let client = Self.client(server)
    let call = Client.Call(method: "POST", path: "chat/completions", body: .json(Data("{}".utf8)), wait: 1)

    _ = try await client.send(budget: 20) { _ in call }
    let taken = try await Self.seconds { _ = try await client.send(budget: 20) { _ in call } }

    // No second second of waiting: the dead connection was dropped for good.
    #expect(taken < 0.9, "took \(taken) s")
    #expect(!server.requests.dropFirst().contains { $0.connection == 1 })
  }

  @Test func aServerThatNeverAnswersFailsAfterTwoShortTries() async throws {
    let server = try QuietServer { _ in .silence }
    let client = Self.client(server)
    var error: WisperError?

    let taken = await Self.seconds {
      error = await wisperError {
        _ = try await client.send(budget: 20) { _ in
          Client.Call(method: "POST", path: "chat/completions", body: .json(Data("{}".utf8)), wait: 0.5)
        }
      }
    }

    #expect(error == .noAnswer)
    // Half a second, then a whole one on a new connection. Nowhere near the 20-second allowance.
    #expect((1.4...4).contains(taken), "took \(taken) s")
    #expect(server.requests.map(\.connection) == [1, 2])
  }

  @Test func theWholeCallNeverOutlastsItsAllowance() async throws {
    let server = try QuietServer { _ in .silence }
    let client = Self.client(server)
    var error: WisperError?

    let taken = await Self.seconds {
      error = await wisperError {
        _ = try await client.send(budget: 1.2) { _ in
          Client.Call(method: "POST", path: "chat/completions", body: .json(Data("{}".utf8)), wait: 1)
        }
      }
    }

    #expect(error == .noAnswer)
    #expect((1.1...2.5).contains(taken), "took \(taken) s")
  }

  @Test func aStalledRequestStopsWhenItsTaskIsCancelled() async throws {
    let server = try QuietServer { _ in .silence }
    let client = Self.client(server)

    let task = Task {
      try await client.send(budget: 60) { _ in
        Client.Call(method: "POST", path: "chat/completions", body: .json(Data("{}".utf8)), wait: 30)
      }
    }
    for _ in 0..<400 where server.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    let taken = await Self.seconds {
      task.cancel()
      await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    #expect(taken < 1, "took \(taken) s")
    #expect(server.requests.count == 1)
  }

  @Test func aSlowButHealthyServerIsNotCutOff() async throws {
    let server = try QuietServer { _ in
      Thread.sleep(forTimeInterval: 0.6)
      return QuietServer.ok(Self.helloBody)
    }
    let client = Self.client(server)

    _ = try await client.send(budget: 20) { _ in
      Client.Call(method: "POST", path: "chat/completions", body: .json(Data("{}".utf8)), wait: 2)
    }

    #expect(server.requests.count == 1)
  }

  @Test func aShortDictationToOpenAIWaitsAboutFiveSecondsThenTwiceThat() {
    // 20 KB: about five seconds of speech as the app records it.
    let short = OpenAITranscriber.limits(bytes: 20 * 1_024, openAI: true)
    #expect((5...6).contains(short.wait))
    // The first try, the second with twice the wait, and room to send the audio: under half a minute.
    #expect((3 * short.wait...30).contains(short.budget))

    // Ten minutes of speech (2.4 MB) gets minutes, not seconds.
    let long = OpenAITranscriber.limits(bytes: 2_400_000, openAI: true)
    #expect(long.wait > 90)
    #expect(long.budget > 3 * long.wait)
    // The largest file OpenAI takes: one patient try inside the longest allowance there is.
    let largest = OpenAITranscriber.limits(bytes: 25 * 1_024 * 1_024, openAI: true)
    #expect(largest.budget == 900)
    #expect(largest.wait <= 300)
  }

  @Test func aServerOfThePersonsOwnIsGivenMoreTime() {
    // A model running on a laptop can need many seconds for a short clip. It is not hurried,
    // and it is not asked twice for the same work while it is still busy with the first.
    let own = OpenAITranscriber.limits(bytes: 20 * 1_024, openAI: false)
    #expect(own.wait >= 20)
    #expect(own.budget >= 3 * own.wait)
  }

  @Test func aSilentUploadTakesTheTimeItsLimitsSay() async throws {
    // The same code path as a dictation, on a real connection, with the limits made small.
    let server = try QuietServer { _ in .silence }
    let client = Self.client(server)
    let audio = try recordings.file(bytes: Data(count: 20 * 1_024))
    let upload = try Upload.write(fields: [("model", "m")], audio: audio)
    var error: WisperError?

    let taken = await Self.seconds {
      error = await wisperError {
        _ = try await client.send(budget: 20) { _ in
          Client.Call(
            method: "POST",
            path: "audio/transcriptions",
            body: .file(upload.file, contentType: upload.contentType),
            wait: 0.6
          )
        }
      }
    }

    #expect(error == .noAnswer)
    // 0.6 s, then 1.2 s on a new connection: the upload itself did not count against the wait.
    #expect((1.7...4).contains(taken), "took \(taken) s")
    #expect(server.requests.map(\.connection) == [1, 2])
    #expect(server.requests.allSatisfy { $0.request.body.count > 20 * 1_024 })
  }

  // MARK: Getting ready

  @Test func preparingOpensAConnectionWithoutSendingTheKeyOrAnythingSaid() async throws {
    let server = try QuietServer { seen in
      seen.method == "HEAD" ? QuietServer.unauthorized : QuietServer.ok(Self.helloBody)
    }
    let client = Self.client(server)

    await client.prepare()

    #expect(server.requests.map(\.request.line) == ["HEAD /v1/models HTTP/1.1"])
    #expect(server.requests[0].request.headers["authorization"] == nil)
    #expect(server.requests[0].request.body.isEmpty)

    // The request that follows travels on the connection that is already open, and it is the
    // one that carries the key.
    _ = try await client.send(budget: 20) { _ in
      Client.Call(method: "POST", path: "chat/completions", body: .json(Data("{}".utf8)), wait: 2)
    }
    #expect(server.requests.map(\.method) == ["HEAD", "POST"])
    #expect(server.requests.map(\.connection) == [1, 1])
    #expect(server.requests[1].request.headers["authorization"] == "Bearer sk-local")
  }

  @Test func preparingFindsADeadConnectionBeforeTheRequestNeedsIt() async throws {
    // The first connection works once and then never answers again, like one that died
    // quietly between two dictations. Without the check, the request below would be written
    // into it and wait.
    let server = try QuietServer { seen in
      if seen.connection == 1, seen.method != "GET" { return .silence }
      return seen.method == "HEAD" ? QuietServer.unauthorized : QuietServer.ok(Self.helloBody)
    }
    let clock = Clock()
    let connections = Self.connections(clock)
    let client = Self.client(server, connections: connections)
    _ = try await client.send(budget: 20) { _ in Client.Call(method: "GET", path: "models", wait: 5) }
    clock.pass(30)

    await client.prepare()
    let taken = try await Self.seconds {
      _ = try await client.send(budget: 20) { _ in
        Client.Call(method: "POST", path: "chat/completions", body: .json(Data("{}".utf8)), wait: 5)
      }
    }

    #expect(taken < 1, "took \(taken) s")
    #expect(connections.sessionsMade == 2)
    #expect(server.requests.map(\.method) == ["GET", "HEAD", "HEAD", "POST"])
    #expect(server.requests.map(\.connection) == [1, 1, 2, 2])
  }

  @Test func aCheckThatFindsNoLifeReplacesTheSessionAndOpensTheNewOne() async throws {
    let clock = Clock()
    let connections = Self.connections(clock)
    let probed = Probed()
    // The session has been in use, a while ago.
    await connections.warm { session, probe in await probed.note(session, probe) > 0 }
    clock.pass(20)

    await connections.warm { session, probe in await probed.note(session, probe) == 2 ? false : true }

    // It gave no sign of life. A second one was made and opened.
    let sessions = await probed.sessions
    #expect(await probed.kinds == [.open, .check, .open])
    try #require(sessions.count == 3)
    #expect(sessions[0] === sessions[1])
    #expect(sessions[1] !== sessions[2])
    #expect(connections.sessionsMade == 2)
    #expect(connections.current() === sessions[2])
  }

  @Test func aNewSessionThatCannotOpenAConnectionIsNotReplacedByAnother() async {
    // Offline, say: a second new session would be no better than the first.
    let connections = Self.connections(Clock())
    let probed = Probed()

    await connections.warm { session, probe in
      _ = await probed.note(session, probe)
      return false
    }

    #expect(await probed.kinds == [.open])
    #expect(connections.sessionsMade == 1)
  }

  @Test func aCheckThatFindsLifeKeepsTheSessionAndIsNotRepeatedRightAway() async {
    let clock = Clock()
    let connections = Self.connections(clock)
    let probed = Probed()

    await connections.warm { session, probe in await probed.note(session, probe) > 0 }
    clock.pass(2)
    await connections.warm { session, probe in await probed.note(session, probe) > 0 }
    #expect(await probed.sessions.count == 1)
    #expect(connections.sessionsMade == 1)

    // A while later nothing is taken on trust any more.
    clock.pass(20)
    await connections.warm { session, probe in await probed.note(session, probe) > 0 }
    #expect(await probed.kinds == [.open, .check])
    #expect(connections.sessionsMade == 1)
  }

  @Test func aRequestIsHeldOnlyUntilTheCheckHasItsAnswer() async {
    let clock = Clock()
    let connections = Self.connections(clock)
    let first = connections.current()
    let verdict = Gate()
    let opening = Gate()
    let probed = Probed()
    // The session has been in use, a while ago.
    await connections.warm { session, probe in await probed.note(session, probe) > 0 }
    clock.pass(20)

    let warming = Task {
      await connections.warm { session, probe in
        _ = await probed.note(session, probe)
        if probe == .check {
          await verdict.pass()
          return false
        }
        // Opening the new connection takes for ever. Nobody waits for that.
        await opening.pass()
        return true
      }
    }
    await verdict.arrival()
    let waiting = Task { () -> URLSession in
      await connections.settled()
      return connections.current()
    }
    await verdict.open()

    #expect(await waiting.value !== first)
    await opening.open()
    await warming.value
  }

  @Test func aRequestDoesNotWaitForAFirstConnectionToOpen() async {
    let connections = Self.connections(Clock())
    let opening = Gate()

    let warming = Task {
      await connections.warm { _, _ in
        await opening.pass()
        return true
      }
    }
    await opening.arrival()
    // Returns although the opening is still going on: the request joins it.
    await connections.settled()

    await opening.open()
    await warming.value
  }

  actor Probed {
    private(set) var sessions: [URLSession] = []
    private(set) var kinds: [Connections.Probe] = []

    /// Notes a probe of `session` and returns how many there have been.
    func note(_ session: URLSession, _ kind: Connections.Probe) -> Int {
      sessions.append(session)
      kinds.append(kind)
      return sessions.count
    }
  }

  /// Holds a step open until the test lets it go.
  actor Gate {
    private var isOpen = false
    private var arrived = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func pass() async {
      arrived = true
      watchers.forEach { $0.resume() }
      watchers = []
      if !isOpen { await withCheckedContinuation { held.append($0) } }
    }

    func arrival() async {
      if !arrived { await withCheckedContinuation { watchers.append($0) } }
    }

    func open() {
      isOpen = true
      held.forEach { $0.resume() }
      held = []
    }
  }

  @Test func aRequestWaitsForACheckThatIsUnderWayInsteadOfUsingTheDeadConnection() async throws {
    let server = try QuietServer { seen in
      if seen.connection == 1, seen.method != "GET" { return .silence }
      return seen.method == "HEAD" ? QuietServer.unauthorized : QuietServer.ok(Self.helloBody)
    }
    let clock = Clock()
    let client = Self.client(server, connections: Self.connections(clock))
    _ = try await client.send(budget: 20) { _ in Client.Call(method: "GET", path: "models", wait: 5) }
    clock.pass(30)

    // The key goes down and is let go at once: the request arrives while the check still runs.
    let preparing = Task { await client.prepare() }
    for _ in 0..<400 where server.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    _ = try await client.send(budget: 20) { _ in
      Client.Call(method: "POST", path: "chat/completions", body: .json(Data("{}".utf8)), wait: 5)
    }
    await preparing.value

    // It went out once, and not on the connection the check found dead.
    let posts = server.requests.filter { $0.method == "POST" }
    #expect(posts.count == 1)
    #expect(posts.first?.connection != 1)
  }

  @Test func preparingSendsNothingWhenARequestCouldNotBeSentEither() async throws {
    let server = Server(.ok("{}"))

    // No key for OpenAI.
    await server.client(key: nil).prepare()
    // An address that cannot be used.
    await Client(
      secrets: InMemorySecretStore(apiKey: "sk-test-key"),
      address: { "not a url" },
      connections: Connections(fixed: server.session)
    ) { _ in }.prepare()

    #expect(server.requests.isEmpty)
  }

  @Test func theTranscriberPreparesThroughTheSeam() async throws {
    let server = Server(.reply(status: 401, body: ""))
    let transcriber: any Transcriber = server.openAI().transcriber

    await transcriber.prepare()

    #expect(server.requests.map(\.method) == ["HEAD"])
    #expect(server.requests.map(\.url.absoluteString) == ["https://api.openai.com/v1/models"])
    #expect(server.requests[0].header("Authorization") == nil)
  }

  // MARK: When a session is no longer trusted

  final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var moment = Connections.Moment(elapsed: 0, awake: 0)

    var now: Connections.Moment { lock.withLock { moment } }

    /// Time passes with the machine awake.
    func pass(_ seconds: TimeInterval) {
      lock.withLock {
        moment.elapsed += seconds
        moment.awake += seconds
      }
    }

    /// Time passes with the machine asleep.
    func sleep(_ seconds: TimeInterval) { lock.withLock { moment.elapsed += seconds } }
  }

  static func connections(_ clock: Clock) -> Connections {
    Connections(make: { URLSession(configuration: .ephemeral) }, watchesNetwork: false, now: { clock.now })
  }

  @Test func keepsTheSessionWhileItIsInUse() {
    let clock = Clock()
    let connections = Self.connections(clock)

    let first = connections.current()
    for _ in 0..<10 {
      clock.pass(30)
      #expect(connections.current() === first)
    }
    #expect(connections.sessionsMade == 1)
  }

  @Test func doesNotTrustAConnectionNobodyUsedForAMinute() {
    let clock = Clock()
    let connections = Self.connections(clock)

    let first = connections.current()
    clock.pass(61)

    #expect(connections.current() !== first)
    #expect(connections.sessionsMade == 2)
  }

  @Test func doesNotTrustAConnectionAfterTheMachineSlept() {
    let clock = Clock()
    let connections = Self.connections(clock)

    let first = connections.current()
    clock.pass(5)
    clock.sleep(8)

    #expect(connections.current() !== first)
  }

  @Test func doesNotTrustAConnectionAfterTheNetworkChanged() {
    let clock = Clock()
    let connections = Self.connections(clock)

    let first = connections.current()
    // The system's first report only says what the network is.
    connections.networkReported()
    #expect(connections.current() === first)

    connections.networkReported()
    let second = connections.current()
    #expect(second !== first)
    // Once is enough.
    #expect(connections.current() === second)
  }

  @Test func twoRequestsThatFailTogetherReplaceTheSessionOnce() {
    let connections = Self.connections(Clock())

    let failed = connections.current()
    connections.renew(after: failed)
    connections.renew(after: failed)

    #expect(connections.sessionsMade == 2)
  }

  @Test func neverReplacesASessionThatWasHandedIn() {
    let session = URLSession(configuration: .ephemeral)
    let connections = Connections(fixed: session)

    connections.networkReported()
    connections.networkReported()
    connections.renew(after: session)

    #expect(connections.current() === session)
    #expect(connections.sessionsMade == 1)
  }

  @Test func sessionsOfOurOwnKeepNothingAndDoNotWaitForANetwork() {
    let configuration = Connections.newSession().configuration

    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.urlCache == nil)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.waitsForConnectivity == false)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
  }
}
