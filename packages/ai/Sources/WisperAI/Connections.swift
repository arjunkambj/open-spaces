import Foundation
import Network

/// The network session requests travel on, and the rule for when to stop trusting it.
///
/// A session keeps its connections open between requests, which is what makes the second
/// request fast. But a connection can die without a word: the Mac slept, the network or a VPN
/// changed underneath it, or the far side dropped it while it sat unused. A request written
/// into such a connection gets no answer and no error, and a retry on the same session is
/// written into the same dead connection.
///
/// So this hands out a **fresh session** (new connections, nothing carried over) whenever the
/// old one cannot be trusted:
///
/// - nothing used it for more than `longestIdle` seconds;
/// - the machine slept since it was last used;
/// - the network changed (Wi-Fi to cable, a VPN going up or down);
/// - a request on it got no answer (`renew`).
///
/// A session that was handed in from outside (tests, an app with its own) is used as it is and
/// never replaced.
///
/// `@unchecked Sendable`: every mutable property is read and written while holding `lock`.
final class Connections: @unchecked Sendable {
  /// A connection nobody used for this long is not trusted. Opening a new one costs a fraction
  /// of a second, and that is paid while the person is still speaking (see `warm`); writing
  /// into a dead one costs the whole wait for an answer.
  static let longestIdle: TimeInterval = 60

  /// A point in time on two clocks: one that keeps counting while the machine sleeps, and one
  /// that stops. When they disagree, the machine slept in between.
  struct Moment: Sendable {
    var elapsed: TimeInterval
    var awake: TimeInterval
  }

  private let make: (@Sendable () -> URLSession)?
  private let now: @Sendable () -> Moment
  private let lock = NSLock()
  private var session: URLSession
  /// When the session was last handed out or carried an answer.
  private var lastUse: Moment?
  /// When the session last carried an answer.
  private var lastAnswer: Moment?
  private var networkChanged = false
  private var sawFirstPath = false
  private var made = 1
  /// The warming that is under way.
  private var warming: Task<Void, Never>?
  /// Whether a connection that was in use is being checked, with no answer yet.
  private var checking = false
  /// Requests waiting for that answer.
  private var checkWaiters: [CheckedContinuation<Void, Never>] = []
  private var monitor: NWPathMonitor?

  /// Uses `session` for everything and never replaces it.
  init(fixed session: URLSession) {
    make = nil
    now = Connections.clock
    self.session = session
  }

  /// Makes sessions with `make`, and replaces the current one when it cannot be trusted.
  ///
  /// - Parameters:
  ///   - watchesNetwork: Whether to notice the network changing. Off in tests.
  ///   - now: The time. Tests pass their own.
  init(
    make: @escaping @Sendable () -> URLSession = Connections.newSession,
    watchesNetwork: Bool = true,
    now: @escaping @Sendable () -> Moment = Connections.clock
  ) {
    self.make = make
    self.now = now
    session = make()
    guard watchesNetwork else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] _ in self?.networkReported() }
    monitor.start(queue: DispatchQueue(label: "openwisper.ai.network", qos: .utility))
    self.monitor = monitor
  }

  deinit {
    monitor?.cancel()
    if make != nil { session.finishTasksAndInvalidate() }
  }

  /// How many sessions have been made so far. For tests.
  var sessionsMade: Int { lock.withLock { made } }

  /// The session to send the next request on: a fresh one when the last cannot be trusted.
  func current() -> URLSession {
    lock.withLock {
      let moment = now()
      if make != nil {
        var stale = networkChanged
        if let lastUse {
          let elapsed = moment.elapsed - lastUse.elapsed
          let asleep = elapsed - (moment.awake - lastUse.awake)
          if elapsed > Connections.longestIdle || asleep > 1 { stale = true }
        }
        if stale { replace() }
      }
      lastUse = moment
      return session
    }
  }

  /// Notes that `session` just carried an answer, so its connection works.
  func used(_ session: URLSession) {
    lock.withLock {
      guard session === self.session else { return }
      lastUse = now()
      lastAnswer = lastUse
    }
  }

  /// Stops using `failed`: the next request goes out on a fresh session, with new connections.
  /// Does nothing when `failed` has been replaced already, so two requests that fail together
  /// do not throw away the session made for the first.
  func renew(after failed: URLSession) {
    lock.withLock {
      if make != nil, failed === session { replace() }
    }
  }

  /// Takes a report about the network from the system. The first one only says what the
  /// network is. Every later one means it changed.
  func networkReported() {
    lock.withLock {
      if sawFirstPath { networkChanged = true }
      sawFirstPath = true
    }
  }

  /// A connection that carried an answer this recently is known to work, so `warm` leaves it alone.
  static let provenFor: TimeInterval = 5

  /// What `warm` is asking a probe to do.
  enum Probe: Sendable {
    /// The session has carried answers before: see whether its connection still works.
    case check
    /// The session is new: open its first connection. That can take a while (seconds, on
    /// some VPNs) and says nothing against the connection.
    case open
  }

  /// Gets a working connection ready before it is needed: opens one when there is none, and
  /// checks the one there is. When the check finds it dead, the session is replaced and a
  /// connection is opened on the fresh one.
  ///
  /// One run at a time: a second caller waits for the one under way.
  ///
  /// - Parameter probe: Sends something small on the session and returns `false` only when
  ///   the connection gave no sign of life.
  func warm(_ probe: @escaping @Sendable (URLSession, Probe) async -> Bool) async {
    let task = lock.withLock { () -> Task<Void, Never> in
      if let warming { return warming }
      let task = Task { [weak self] in
        guard let self else { return }
        defer { self.finishedWarming() }
        if self.isProven() { return }
        let (first, kind) = self.beginProbe()
        if await probe(first, kind) {
          self.used(first)
          return self.finishedChecking()
        }
        // A new session that could not open a connection is not replaced by another new one:
        // nothing would be different. The request itself will find out and say why.
        guard kind == .check else { return }
        self.renew(after: first)
        // What matters to a waiting request is known now: the old session is gone. Opening a
        // connection on the new one goes on without holding that request up.
        self.finishedChecking()
        let second = self.current()
        if second !== first, await probe(second, .open) { self.used(second) }
      }
      warming = task
      return task
    }
    await task.value
  }

  /// Returns once no check of a connection that was in use is under way, so a request is not
  /// written into a connection that is about to be found dead. (The opening of a first
  /// connection is not waited for: the request joins it.)
  func settled() async {
    await withCheckedContinuation { continuation in
      let none = lock.withLock { () -> Bool in
        if !checking { return true }
        checkWaiters.append(continuation)
        return false
      }
      if none { continuation.resume() }
    }
  }

  /// The session to probe, and whether that is a check of a used one or the opening of a new one.
  private func beginProbe() -> (URLSession, Probe) {
    let session = current()
    return lock.withLock {
      let kind: Probe = session === self.session && lastAnswer != nil ? .check : .open
      checking = kind == .check
      return (session, kind)
    }
  }

  private func isProven() -> Bool {
    lock.withLock {
      guard let lastAnswer, !networkChanged else { return false }
      let moment = now()
      let elapsed = moment.elapsed - lastAnswer.elapsed
      return elapsed <= Connections.provenFor && elapsed - (moment.awake - lastAnswer.awake) <= 1
    }
  }

  private func finishedChecking() {
    let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      checking = false
      defer { checkWaiters = [] }
      return checkWaiters
    }
    for waiter in waiting { waiter.resume() }
  }

  private func finishedWarming() {
    lock.withLock { warming = nil }
    finishedChecking()
  }

  /// Call with `lock` held.
  private func replace() {
    guard let make else { return }
    let old = session
    session = make()
    made += 1
    networkChanged = false
    lastUse = nil
    lastAnswer = nil
    // Requests still under way on the old session run to their end; nothing new starts on it.
    old.finishTasksAndInvalidate()
  }

  // MARK: Defaults

  /// A session of our own: nothing shared with other apps or with the rest of this one.
  ///
  /// - Kept in memory only: no cookies, no cache, no saved credentials. A cached "OK" would
  ///   make a bad key look good, and nothing about a request belongs on disk.
  /// - `waitsForConnectivity` is off: with no network the request fails at once and the person
  ///   is told, instead of the app sitting on a recording.
  /// - The traffic is marked as something a person is waiting for.
  /// - HTTP/2 is used where the server offers it, which lets the clean-up request ride on the
  ///   connection the upload just used. HTTP/3 is not asked for: it runs over UDP, which some
  ///   VPNs and office networks drop. (The system may still pick it by itself when a server
  ///   advertises it. There is no public switch to forbid that. A stalled request is retried
  ///   on a fresh session whichever protocol it used.)
  static let newSession: @Sendable () -> URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.waitsForConnectivity = false
    // A backstop only: every call has its own, shorter, limit.
    configuration.timeoutIntervalForResource = 20 * 60
    configuration.networkServiceType = .responsiveData
    return URLSession(configuration: configuration)
  }

  /// The real clocks.
  static let clock: @Sendable () -> Moment = {
    Moment(
      elapsed: seconds(ContinuousClock.now - origin.continuous),
      awake: seconds(SuspendingClock.now - origin.suspending)
    )
  }

  private static let origin = (continuous: ContinuousClock.now, suspending: SuspendingClock.now)

  private static func seconds(_ duration: Duration) -> TimeInterval {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
