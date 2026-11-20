import AVFoundation
import SpacesDomain

#if os(macOS)
  import CoreAudio
#endif

/// The microphone, read with an `AVAudioEngine` input tap.
///
/// Keeps going when the input device changes (headphones connect, the default
/// microphone is switched, a phone call interrupts): the engine is rebuilt on
/// the new device and sound carries on into the same sink.
///
/// `@unchecked Sendable`: every mutable property is read and written on
/// `control` only.
final class MicrophoneSource: AudioSource, @unchecked Sendable {
  private let preferredID: String?
  private let control = DispatchQueue(label: "openspaces.audio.microphone", qos: .userInitiated)
  private var sink: SampleSink?
  private var engine: AVAudioEngine?
  private var progress = Progress()
  /// The format the tap was installed with.
  private var tapFormat: AVAudioFormat?
  /// Whether the queued rebuild must happen even if the engine looks fine.
  private var mustRebuild = false
  private var observers: [any NSObjectProtocol] = []
  private var isRunning = false
  private var pendingRebuild: DispatchWorkItem?
  #if os(macOS)
    private var watches: [HardwareWatch] = []
    /// The device the engine is reading right now.
    private var current: AudioDeviceID?
  #else
    private var sessionObservers: [any NSObjectProtocol] = []
  #endif
  /// Rebuilds that failed in a row.
  private var failures = 0

  /// - Parameter deviceID: The wanted input device, or `nil` for the system default.
  init(deviceID: String?) {
    preferredID = deviceID
  }

  func start(into sink: SampleSink) throws {
    try control.sync {
      guard !isRunning else { return }
      self.sink = sink
      do {
        try prepareSession()
        try buildEngine()
      } catch {
        self.sink = nil
        releaseSession()
        throw error
      }
      isRunning = true
      watchHardware()
    }
  }

  func stop() {
    control.sync {
      guard isRunning else { return }
      isRunning = false
      pendingRebuild?.cancel()
      pendingRebuild = nil
      unwatchHardware()
      // The engine hands sound over a buffer at a time. Wait for the buffer
      // that holds this very moment, so the last word is not cut off.
      if engine?.isRunning == true { progress.wait(until: HostClock.now(), atMost: 0.25) }
      tearDownEngine()
      releaseSession()
      sink = nil
    }
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    #if !os(macOS)
      for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
    #endif
    engine?.stop()
  }

  // MARK: Engine

  private func buildEngine() throws {
    let engine = AVAudioEngine()
    #if os(macOS)
      // A chosen device that is not connected falls back to the default. One
      // that already is the default is left alone: setting it by hand makes
      // the engine reconfigure and lose the first moments of sound.
      let standard = AudioHardware.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
      let chosen = chosenDevice()
      if let chosen, chosen != standard { try? engine.inputNode.auAudioUnit.setDeviceID(chosen) }
      current = chosen ?? standard
    #endif
    try run(engine)
    self.engine = engine

    // Posted when the device or its format changes, after the engine has
    // stopped itself. (It also comes once shortly after a device is set by
    // hand.) The same engine can be started again on the new format.
    let observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      self?.onControl { $0.queueRebuild(after: .milliseconds(20), onlyIfBroken: true) }
    }
    observers.append(observer)
  }

  /// Installs the tap in the input's present format and starts `engine`.
  private func run(_ engine: AVAudioEngine) throws {
    guard let sink else { throw SpacesError.captureFailed("The microphone could not be started.") }
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw SpacesError.captureFailed("No microphone was found.")
    }
    // Ask for about 50 ms a buffer. The system may hand over more at a time.
    let size = AVAudioFrameCount(format.sampleRate / 20)
    let progress = Progress()
    let block = MicrophoneSource.tap(into: sink, noting: progress)
    input.installTap(onBus: 0, bufferSize: size, format: format, block: block)
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw SpacesError.captureFailed("The microphone could not be started.")
    }
    self.progress = progress
    tapFormat = format
  }

  /// Starts the same engine again after the system changed its setup and
  /// stopped it. Returns whether that worked.
  private func restartEngine() -> Bool {
    guard let engine else { return false }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    tapFormat = nil
    return (try? run(engine)) != nil
  }

  private func tearDownEngine() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    guard let engine else { return }
    self.engine = nil
    tapFormat = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }

  /// The block the engine calls with each buffer. It runs on a thread the
  /// engine owns (not the real-time one), so copying the samples is fine.
  /// Built in a static method so it takes on no actor or `self`.
  private static func tap(into sink: SampleSink, noting progress: Progress) -> AVAudioNodeTapBlock {
    { buffer, when in
      let frames = Int(buffer.frameLength)
      guard frames > 0, let channels = buffer.floatChannelData else { return }
      let rate = buffer.format.sampleRate
      // Microphones sit on the first one or two channels, also on big interfaces.
      var samples = [Float](UnsafeBufferPointer(start: channels[0], count: frames))
      if buffer.format.channelCount > 1 {
        let second = channels[1]
        for index in 0..<frames { samples[index] = (samples[index] + second[index]) / 2 }
      }
      let time =
        when.isHostTimeValid
        ? AVAudioTime.seconds(forHostTime: when.hostTime)
        : HostClock.now() - Double(frames) / rate
      sink.deliver(samples, rate, time)
      progress.reached(time + Double(frames) / rate)
    }
  }

  /// How far the engine's buffers have got, so `stop` can wait for the last one.
  ///
  /// `@unchecked Sendable`: `time` is read and written only while holding `condition`.
  private final class Progress: @unchecked Sendable {
    private let condition = NSCondition()
    private var time: TimeInterval = 0

    /// Notes that sound up to `time` (on `HostClock`) has been handed over.
    func reached(_ time: TimeInterval) {
      condition.lock()
      self.time = max(self.time, time)
      condition.broadcast()
      condition.unlock()
    }

    /// Returns once sound up to `time` has been handed over, or after `limit` seconds.
    func wait(until time: TimeInterval, atMost limit: TimeInterval) {
      let deadline = Date().addingTimeInterval(limit)
      condition.lock()
      while self.time < time, condition.wait(until: deadline) {}
      condition.unlock()
    }
  }

  /// Runs `work` on the control queue, if this source is still around.
  private func onControl(_ work: @escaping @Sendable (MicrophoneSource) -> Void) {
    control.async { [weak self] in
      if let self { work(self) }
    }
  }

  /// Rebuilds the engine after `delay`. A later call replaces an earlier one
  /// that has not run yet, so a burst of change notices leads to one rebuild.
  ///
  /// - Parameter onlyIfBroken: Skip the rebuild when the engine turns out to
  ///   be running in the format it was set up with.
  private func queueRebuild(after delay: DispatchTimeInterval, onlyIfBroken: Bool = false) {
    guard isRunning else { return }
    pendingRebuild?.cancel()
    if !onlyIfBroken { mustRebuild = true }
    let work = DispatchWorkItem { [weak self] in self?.rebuild() }
    pendingRebuild = work
    control.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func rebuild() {
    pendingRebuild = nil
    guard isRunning else { return }
    // The engine stopped itself but the device is the same: start it again.
    if !mustRebuild, engineIsFine || restartEngine() { return }
    mustRebuild = false
    tearDownEngine()
    do {
      try resumeSession()
      try buildEngine()
      failures = 0
    } catch {
      // No usable microphone at this moment (unplugged, or a phone call has
      // it). Try again shortly, then less often.
      failures += 1
      queueRebuild(after: .seconds(failures < 10 ? 1 : 5))
    }
  }

  private var engineIsFine: Bool {
    guard let engine, let tapFormat, engine.isRunning else { return false }
    let format = engine.inputNode.outputFormat(forBus: 0)
    return format.sampleRate == tapFormat.sampleRate && format.channelCount == tapFormat.channelCount
  }

  // MARK: Platform

  #if os(macOS)
    private func prepareSession() throws {}

    private func resumeSession() throws {}

    private func releaseSession() {}

    private func watchHardware() {
      let changed: @Sendable () -> Void = { [weak self] in self?.hardwareChanged() }
      watches = [
        HardwareWatch(kAudioHardwarePropertyDefaultInputDevice, on: control, changed: changed),
        HardwareWatch(kAudioHardwarePropertyDevices, on: control, changed: changed),
      ].compactMap { $0 }
    }

    private func unwatchHardware() { watches = [] }

    /// The device the user picked, when it is connected and can record.
    private func chosenDevice() -> AudioDeviceID? {
      guard let preferredID, let device = AudioHardware.device(uid: preferredID),
        AudioHardware.inputChannels(device) > 0
      else { return nil }
      return device
    }

    /// Moves to the device that should be in use, when that is not the current one.
    ///
    /// Compared against the device that was asked for, not the one the engine
    /// reports: the engine may wrap devices in a private one of its own, and
    /// making that fires this very notice.
    private func hardwareChanged() {
      let wanted = chosenDevice() ?? AudioHardware.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
      if let wanted, wanted != current { queueRebuild(after: .milliseconds(300)) }
    }

    static func devices() -> [AudioDevice] { AudioHardware.microphones() }
  #else
    /// Sets the shared audio session up for recording speech.
    private static func configure(_ session: AVAudioSession) throws {
      // `.playAndRecord` so the app's own sounds can still play; `.measurement`
      // so the system leaves the voice unprocessed for the speech model. Bluetooth
      // headsets are allowed as the microphone: the option is spelled by raw
      // value (0x4) because its name differs between SDK versions
      // (`allowBluetooth`, later `allowBluetoothHFP`).
      let bluetooth = AVAudioSession.CategoryOptions(rawValue: 0x4)
      try session.setCategory(.playAndRecord, mode: .measurement, options: [bluetooth, .defaultToSpeaker])
    }

    private func prepareSession() throws {
      let session = AVAudioSession.sharedInstance()
      do {
        try MicrophoneSource.configure(session)
        try session.setActive(true)
      } catch {
        throw SpacesError.captureFailed("The microphone could not be started.")
      }
      if let preferredID, let port = session.availableInputs?.first(where: { $0.uid == preferredID }) {
        try? session.setPreferredInput(port)
      }
    }

    /// Takes the microphone back after an interruption. Throws while the
    /// system still has it (during a phone call).
    private func resumeSession() throws {
      try AVAudioSession.sharedInstance().setActive(true)
    }

    private func releaseSession() {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func watchHardware() {
      let center = NotificationCenter.default
      let session = AVAudioSession.sharedInstance()
      sessionObservers = [
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) {
          [weak self] note in
          let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
          let began = raw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .began
          self?.onControl { $0.interruption(began: began) }
        },
        center.addObserver(
          forName: AVAudioSession.mediaServicesWereResetNotification,
          object: session,
          queue: nil
        ) { [weak self] _ in
          self?.onControl { $0.sessionWasReset() }
        },
      ]
    }

    private func unwatchHardware() {
      for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
      sessionObservers = []
    }

    /// A phone call (or similar) took the microphone, or gave it back.
    private func interruption(began: Bool) {
      guard isRunning else { return }
      failures = 0
      if began {
        engine?.pause()
        // The system does not always say when an interruption is over, so
        // also check back now and then.
        queueRebuild(after: .seconds(5))
      } else {
        queueRebuild(after: .milliseconds(100))
      }
    }

    /// The system's audio server restarted: everything must be set up again.
    private func sessionWasReset() {
      guard isRunning else { return }
      try? MicrophoneSource.configure(AVAudioSession.sharedInstance())
      queueRebuild(after: .milliseconds(100))
    }

    static func devices() -> [AudioDevice] {
      let session = AVAudioSession.sharedInstance()
      // Inputs are only listed in full for a category that can record.
      if session.category != .playAndRecord && session.category != .record {
        try? configure(session)
      }
      let inputs = session.availableInputs ?? []
      let active = session.currentRoute.inputs.first?.uid ?? session.preferredInput?.uid ?? inputs.first?.uid
      return inputs.map { AudioDevice(id: $0.uid, name: $0.portName, isDefault: $0.uid == active) }
    }
  #endif
}
