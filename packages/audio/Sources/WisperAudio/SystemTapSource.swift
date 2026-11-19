#if os(macOS)
  import AVFoundation
  import CoreAudio
  import WisperDomain

  /// What the computer is playing, recorded with a Core Audio process tap.
  ///
  /// The tap is global (every app's output, mixed to mono) and leaves out this
  /// app's own sound. It needs the "System audio recording" consent only, not
  /// screen recording.
  ///
  /// `@unchecked Sendable`: every mutable property is read and written on
  /// `control` only.
  final class SystemTapSource: AudioSource, @unchecked Sendable {
    private let control = DispatchQueue(label: "openwisper.audio.system", qos: .userInitiated)
    private var sink: SampleSink?
    private var rig: TapRig?
    private var timer: DispatchSourceTimer?
    private var outputWatch: HardwareWatch?
    private var isRunning = false
    private var pendingRebuild: DispatchWorkItem?
    /// Rebuilds that failed in a row.
    private var failures = 0

    func start(into sink: SampleSink) throws {
      try control.sync {
        guard !isRunning else { return }
        rig = try TapRig.make()
        self.sink = sink
        isRunning = true

        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(
          deadline: .now() + .milliseconds(50),
          repeating: .milliseconds(50),
          leeway: .milliseconds(5)
        )
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer

        // The tap follows the output device. When that changes (headphones
        // plugged in), its sample rate can change too, so build it afresh.
        outputWatch = HardwareWatch(kAudioHardwarePropertyDefaultOutputDevice, on: control) { [weak self] in
          self?.queueRebuild(after: .milliseconds(300))
        }
      }
    }

    func stop() {
      control.sync {
        guard isRunning else { return }
        isRunning = false
        pendingRebuild?.cancel()
        pendingRebuild = nil
        outputWatch = nil
        timer?.cancel()
        timer = nil
        rig?.halt()
        drain()
        rig = nil
        sink = nil
      }
    }

    deinit {
      timer?.cancel()
      // `rig` tears itself down as it is released.
    }

    /// Moves what the audio thread has queued on to the sink.
    private func drain() {
      guard let rig, let sink else { return }
      var samples: [Float] = []
      var startTime: TimeInterval?
      rig.relay.drain { block, hostTime, offset in
        if startTime == nil {
          startTime = AVAudioTime.seconds(forHostTime: hostTime) + Double(offset) / rig.sampleRate
        }
        samples.append(contentsOf: block)
      }
      if let startTime, !samples.isEmpty { sink.deliver(samples, rig.sampleRate, startTime) }
    }

    /// Rebuilds the tap after `delay`. A later call replaces an earlier one
    /// that has not run yet.
    private func queueRebuild(after delay: DispatchTimeInterval) {
      guard isRunning else { return }
      pendingRebuild?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.rebuild() }
      pendingRebuild = work
      control.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rebuild() {
      pendingRebuild = nil
      guard isRunning else { return }
      rig?.halt()
      drain()
      rig = nil
      do {
        rig = try TapRig.make()
        failures = 0
      } catch {
        // The audio system is mid-change. Try again shortly, then less often.
        failures += 1
        queueRebuild(after: .seconds(failures < 10 ? 1 : 5))
      }
    }
  }

  /// A running process tap: the tap, the private device that reads it, and the
  /// callback on the audio thread. Everything is removed again in `deinit`, so
  /// nothing is left behind in the user's audio setup.
  private final class TapRig {
    let relay: SampleRelay
    private(set) var sampleRate = 0.0
    private var tap = AudioHardware.unknown
    private var device = AudioHardware.unknown
    private var callback: AudioDeviceIOProcID?
    private var isStarted = false

    static func make() throws -> TapRig {
      guard let relay = SampleRelay() else {
        throw WisperError.captureFailed("There was not enough memory to record system audio.")
      }
      let rig = TapRig(relay: relay)
      // If `open` throws half-way, releasing `rig` removes what it had made.
      try rig.open()
      return rig
    }

    private init(relay: SampleRelay) { self.relay = relay }

    deinit { close() }

    private func open() throws {
      let own = AudioHardware.process(pid: getpid())
      let description = CATapDescription(monoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
      description.name = "Open Wisper"
      description.isPrivate = true
      description.muteBehavior = .unmuted

      // Creating the tap is the step the system refuses without consent.
      guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != AudioHardware.unknown else {
        tap = AudioHardware.unknown
        throw WisperError.permissionDenied(.systemAudio)
      }

      var format = AudioStreamBasicDescription()
      guard AudioHardware.read(tap, kAudioTapPropertyFormat, into: &format),
        format.mFormatID == kAudioFormatLinearPCM,
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
        format.mBitsPerChannel == 32,
        format.mSampleRate > 0
      else { throw WisperError.captureFailed("System audio is in a format that cannot be recorded.") }
      sampleRate = format.mSampleRate

      // A private device holding only the tap. It is not saved and other apps do not see it.
      let tapUID = AudioHardware.string(tap, kAudioTapPropertyUID) ?? description.uuid.uuidString
      let composition: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Open Wisper System Audio",
        kAudioAggregateDeviceUIDKey: AudioHardware.ownDevicePrefix + UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: false,
        kAudioAggregateDeviceTapListKey: [
          [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
        ],
      ]
      var status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device)
      guard status == noErr, device != AudioHardware.unknown else {
        device = AudioHardware.unknown
        throw TapRig.failure("set up", status)
      }

      // The device hands sound over at its own rate, which is normally the tap's.
      var deviceRate = 0.0
      if AudioHardware.read(device, kAudioDevicePropertyNominalSampleRate, into: &deviceRate), deviceRate > 0
      {
        sampleRate = deviceRate
      }

      // No dispatch queue: the block runs on the audio thread itself, so it
      // must not lock, allocate or wait. `SampleRelay.write` does none of those.
      let relay = relay
      status = AudioDeviceCreateIOProcIDWithBlock(&callback, device, nil) { now, input, inputTime, _, _ in
        let stamp = inputTime.pointee
        let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : now.pointee.mHostTime
        relay.write(input, hostTime: hostTime)
      }
      guard status == noErr, callback != nil else {
        callback = nil
        throw TapRig.failure("read", status)
      }

      status = AudioDeviceStart(device, callback)
      guard status == noErr else {
        if status == kAudioDevicePermissionsError { throw WisperError.permissionDenied(.systemAudio) }
        throw TapRig.failure("start", status)
      }
      isStarted = true
    }

    /// Stops the audio thread's callback. What it queued can still be drained.
    func halt() {
      guard isStarted else { return }
      isStarted = false
      AudioDeviceStop(device, callback)
    }

    private func close() {
      halt()
      if let callback {
        AudioDeviceDestroyIOProcID(device, callback)
        self.callback = nil
      }
      if device != AudioHardware.unknown {
        AudioHardwareDestroyAggregateDevice(device)
        device = AudioHardware.unknown
      }
      if tap != AudioHardware.unknown {
        AudioHardwareDestroyProcessTap(tap)
        tap = AudioHardware.unknown
      }
    }

    private static func failure(_ step: String, _ status: OSStatus) -> WisperError {
      .captureFailed("System audio could not be recorded (\(step), code \(status)).")
    }
  }
#endif
