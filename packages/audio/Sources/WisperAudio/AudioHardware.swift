#if os(macOS)
  import CoreAudio
  import Foundation
  import WisperDomain

  /// Small, typed reads of Core Audio's property system.
  enum AudioHardware {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    /// Every private device this package creates has a UID that starts with this.
    static let ownDevicePrefix = "openwisper.system-audio."

    static func address(
      _ selector: AudioObjectPropertySelector,
      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
      AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
      )
    }

    /// Reads a fixed-size property into `value`. Returns whether it worked.
    static func read<Value>(
      _ object: AudioObjectID,
      _ selector: AudioObjectPropertySelector,
      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
      into value: inout Value
    ) -> Bool {
      var address = address(selector, scope: scope)
      var size = UInt32(MemoryLayout<Value>.size)
      return withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
      } == noErr
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
      var value: Unmanaged<CFString>?
      guard read(object, selector, into: &value) else { return nil }
      return value?.takeRetainedValue() as String?
    }

    static func devices() -> [AudioDeviceID] {
      var address = address(kAudioHardwarePropertyDevices)
      var size: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
      var ids = [AudioDeviceID](repeating: unknown, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
      guard !ids.isEmpty, AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
      else { return [] }
      return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    /// How many channels `device` can record.
    static func inputChannels(_ device: AudioDeviceID) -> Int {
      var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
      var size: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
      else { return 0 }
      let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
      )
      defer { raw.deallocate() }
      guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
      let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
      return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
      var device = unknown
      guard read(system, selector, into: &device), device != unknown else { return nil }
      return device
    }

    /// The device with this UID, if it is connected right now.
    static func device(uid: String) -> AudioDeviceID? {
      var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
      var device = unknown
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      var qualifier = uid as CFString
      let status = withUnsafePointer(to: &qualifier) {
        AudioObjectGetPropertyData(
          system,
          &address,
          UInt32(MemoryLayout<CFString>.size),
          $0,
          &size,
          &device
        )
      }
      return status == noErr && device != unknown ? device : nil
    }

    /// Core Audio's object for a running process, used to leave it out of a tap.
    static func process(pid: pid_t) -> AudioObjectID? {
      var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
      var object = unknown
      var size = UInt32(MemoryLayout<AudioObjectID>.size)
      var qualifier = pid
      let status = AudioObjectGetPropertyData(
        system,
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        &qualifier,
        &size,
        &object
      )
      return status == noErr && object != unknown ? object : nil
    }

    /// Whether `device` is a combined device that only this process can see.
    /// Audio frameworks (and this package) make such devices for their own
    /// use; they are not something a person can pick.
    static func isPrivateAggregate(_ device: AudioDeviceID) -> Bool {
      var transport: UInt32 = 0
      guard read(device, kAudioDevicePropertyTransportType, into: &transport),
        transport == kAudioDeviceTransportTypeAggregate
      else { return false }
      var composition: Unmanaged<CFDictionary>?
      guard read(device, kAudioAggregateDevicePropertyComposition, into: &composition),
        let values = composition?.takeRetainedValue() as? [String: Any]
      else { return false }
      return (values[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
    }

    /// Input devices a person could pick as their microphone.
    static func microphones() -> [AudioDevice] {
      let preferred = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
      return devices().compactMap { device in
        guard inputChannels(device) > 0, !isPrivateAggregate(device),
          let uid = string(device, kAudioDevicePropertyDeviceUID),
          !uid.hasPrefix(ownDevicePrefix)
        else { return nil }
        let name = string(device, kAudioObjectPropertyName) ?? "Microphone"
        return AudioDevice(id: uid, name: name, isDefault: device == preferred)
      }
    }
  }

  /// Calls back when one property of the audio system changes, until dropped.
  ///
  /// `@unchecked Sendable`: immutable after `init`; the stored block is only
  /// handed back to Core Audio to remove it.
  final class HardwareWatch: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    /// - Parameter queue: Where `changed` runs.
    init?(
      _ selector: AudioObjectPropertySelector,
      of object: AudioObjectID = AudioHardware.system,
      on queue: DispatchQueue,
      changed: @escaping @Sendable () -> Void
    ) {
      self.object = object
      self.queue = queue
      address = AudioHardware.address(selector)
      block = { _, _ in changed() }
      guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
    }

    deinit {
      AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
  }
#endif
