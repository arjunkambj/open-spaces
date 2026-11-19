#if os(macOS)
  import CoreAudio
  import Foundation
  import Testing

  @testable import WisperAudio

  /// Counts calls from any thread.
  private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }

    /// Waits until at least `wanted` calls have come in. Returns whether they did.
    func reaches(_ wanted: Int, within seconds: Double = 5) async -> Bool {
      let deadline = Date().addingTimeInterval(seconds)
      while value < wanted, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
      return value >= wanted
    }
  }

  /// The watch is tested on a setting that belongs to this test process alone: whether it
  /// lets the audio system unload itself when idle. Nothing the user has set up is touched.
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct HardwareWatchTests {
    private static let selector = kAudioHardwarePropertyUnloadingIsAllowed

    /// Flips the setting and puts it back, which tells every listener twice.
    /// Returns whether the audio system took both changes.
    @discardableResult
    private static func nudge() -> Bool {
      var address = AudioHardware.address(selector)
      var value: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      guard AudioObjectGetPropertyData(AudioHardware.system, &address, 0, nil, &size, &value) == noErr
      else { return false }
      var flipped: UInt32 = value == 0 ? 1 : 0
      let there = AudioObjectSetPropertyData(AudioHardware.system, &address, 0, nil, size, &flipped)
      let back = AudioObjectSetPropertyData(AudioHardware.system, &address, 0, nil, size, &value)
      return there == noErr && back == noErr
    }

    /// Lets changes that are already on their way arrive, and the queue run them.
    private static func settle(_ queue: DispatchQueue) async throws {
      try await Task.sleep(for: .milliseconds(300))
      queue.sync {}
    }

    // A machine with no audio system at all (some build machines) cannot run this.
    @Test(.enabled(if: nudge()))
    func aDroppedWatchIsNoLongerCalled() async throws {
      let queue = DispatchQueue(label: "openwisper.tests.watch")
      let dropped = Tally()
      do {
        let watch = try #require(HardwareWatch(HardwareWatchTests.selector, on: queue) { dropped.add() })
        HardwareWatchTests.nudge()
        // It works while it is held.
        #expect(await dropped.reaches(1))
        try await HardwareWatchTests.settle(queue)
        withExtendedLifetime(watch) {}
      }
      let callsWhileHeld = dropped.value
      let systemCalls = HardwareWatch.callsFromTheSystem

      HardwareWatchTests.nudge()
      try await HardwareWatchTests.settle(queue)
      #expect(dropped.value == callsWhileHeld)
      // Not merely ignored: the audio system no longer calls for it at all.
      #expect(HardwareWatch.callsFromTheSystem == systemCalls)
    }

    @Test(.enabled(if: nudge()))
    func watchesComeAndGoWithoutPilingUp() async throws {
      let queue = DispatchQueue(label: "openwisper.tests.watch.many")
      let stale = Tally()
      // As many watches as a day of dictations makes, each dropped at once.
      for _ in 0..<50 {
        _ = try #require(HardwareWatch(HardwareWatchTests.selector, on: queue) { stale.add() })
      }
      let systemCalls = HardwareWatch.callsFromTheSystem
      let witnessed = Tally()
      let witness = try #require(HardwareWatch(HardwareWatchTests.selector, on: queue) { witnessed.add() })
      HardwareWatchTests.nudge()
      // The one watch still held is the witness that the change really was announced.
      #expect(await witnessed.reaches(1))
      try await HardwareWatchTests.settle(queue)
      withExtendedLifetime(witness) {}

      #expect(stale.value == 0)
      // One change there and one back, for the one watch that is left.
      #expect(HardwareWatch.callsFromTheSystem - systemCalls <= 2)
    }
  }
#endif
