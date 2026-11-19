import Accelerate
import AudioToolbox
import Foundation

/// The shape of every file this package writes: speech-sized AAC in `.m4a`.
enum Encoding {
  /// 16 kHz is what speech models work at; more only makes files bigger.
  static let sampleRate = 16_000.0
  /// 32 kbps mono AAC: about 240 KB a minute, and clear enough for transcription.
  static let bitRate: UInt32 = 32_000
}

/// One `.m4a` file being written. Takes mono 16 kHz samples, encodes them to AAC.
///
/// Written with `ExtAudioFile` rather than `AVAudioFile` for two reasons:
/// closing is immediate and certain on every OS version we support, and the
/// space set aside at the front of the file can be sized to the recording
/// (about 2.5 KB instead of a fixed 23 KB, which matters for short files).
///
/// Not thread-safe: used on one queue.
final class EncodedFile {
  let url: URL
  private(set) var frames = 0
  private var file: ExtAudioFileRef?
  private var copy: SafetyCopy?

  /// - Parameters:
  ///   - expectedSeconds: About how long the file will be. A longer file is still valid;
  ///     its index just lands at the end instead of the front.
  ///   - keepsCopy: Whether the sound is also kept in a `SafetyCopy` until the file is closed.
  init?(url: URL, expectedSeconds: Double, keepsCopy: Bool = false) {
    self.url = url
    // Made first, so there is never an open `.m4a` without its copy.
    if keepsCopy { copy = SafetyCopy(beside: url) }
    var format = AudioStreamBasicDescription(
      mSampleRate: Encoding.sampleRate,
      mFormatID: kAudioFormatMPEG4AAC,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: 1_024,
      mBytesPerFrame: 0,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 0,
      mReserved: 0
    )
    // Made here first, so the file is private from its first byte: only the user's own account
    // may read a recording. The audio system then fills the file it finds.
    let made = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    if made >= 0 { Darwin.close(made) }
    let flags = AudioFileFlags.eraseFile.rawValue
    guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &format, nil, flags, &file) == noErr,
      let file
    else {
      copy?.remove()
      return nil
    }
    // In case the audio system put a new file in its place, or the file was there before.
    chmod(url.path, 0o600)

    // Best effort: when this fails the file is still right, only a little larger.
    var container: AudioFileID?
    var size = UInt32(MemoryLayout<AudioFileID?>.size)
    if ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &container) == noErr,
      let container
    {
      var reserve = max(0, expectedSeconds)
      AudioFileSetProperty(
        container,
        kAudioFilePropertyReserveDuration,
        UInt32(MemoryLayout<Float64>.size),
        &reserve
      )
    }

    #if !os(macOS)
      // The software encoder keeps working in the background and during
      // interruptions on iOS, where the hardware one does not. The value is
      // `kAppleSoftwareAudioCodecManufacturer` ('appl'), written out so its
      // imported type cannot differ between SDK versions.
      var maker: UInt32 = 0x6170_706C
      ExtAudioFileSetProperty(
        file,
        kExtAudioFileProperty_CodecManufacturer,
        UInt32(MemoryLayout<UInt32>.size),
        &maker
      )
    #endif

    var input = AudioStreamBasicDescription(
      mSampleRate: Encoding.sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    guard
      ExtAudioFileSetProperty(
        file,
        kExtAudioFileProperty_ClientDataFormat,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
        &input
      ) == noErr
    else {
      remove()
      return nil
    }

    var converter: AudioConverterRef?
    size = UInt32(MemoryLayout<AudioConverterRef?>.size)
    if ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr,
      let converter
    {
      var rate = Encoding.bitRate
      AudioConverterSetProperty(
        converter,
        kAudioConverterEncodeBitRate,
        UInt32(MemoryLayout<UInt32>.size),
        &rate
      )
      // Tells the file that its encoder's settings changed. The value is a
      // null `CFArray` reference, which means "read them from the encoder".
      var config: UnsafeRawPointer?
      ExtAudioFileSetProperty(
        file,
        kExtAudioFileProperty_ConverterConfig,
        UInt32(MemoryLayout<UnsafeRawPointer?>.size),
        &config
      )
    }
  }

  deinit { close() }

  /// Adds samples. Returns `false` when they could not be written (disk full,
  /// folder gone).
  func write(_ samples: UnsafeBufferPointer<Float>) -> Bool {
    guard let file, let base = samples.baseAddress, !samples.isEmpty else { return false }
    copy?.write(samples)
    var list = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.stride),
        mData: UnsafeMutableRawPointer(mutating: base)
      )
    )
    guard ExtAudioFileWrite(file, UInt32(samples.count), &list) == noErr else { return false }
    frames += samples.count
    return true
  }

  /// Finishes the file. It is complete and playable when this returns. Safe to call twice.
  func close() {
    guard let file else { return }
    self.file = nil
    ExtAudioFileDispose(file)
    // The file can be read now, so the copy has done its job.
    copy?.remove()
    copy = nil
  }

  /// Closes the file and deletes it.
  func remove() {
    close()
    try? FileManager.default.removeItem(at: url)
  }
}

/// A plain copy of the sound in an `.m4a` that is still being written.
///
/// An `.m4a` can only be read once it is closed, because its index is written last. If the
/// app is killed before that, the sound in it is gone. So the same samples are also kept next
/// to it as `<name>.wav` (16-bit, 16 kHz, mono), whose header is brought up to date after
/// every write: that file can be read at any moment and needs no closing step. Whoever finds
/// a `.wav` beside an `.m4a` that cannot be read uses the `.wav` instead. The copy is deleted
/// when the `.m4a` is closed.
///
/// It costs 32 KB of disk a second for as long as a file is open. Not thread-safe.
final class SafetyCopy {
  static let fileExtension = "wav"

  let url: URL
  private var descriptor: Int32
  /// Bytes of sound written so far.
  private var bytes = 0

  /// Starts the copy for the audio file at `url`. `nil` when it cannot be created, or when
  /// a file with its name is already there.
  init?(beside url: URL) {
    self.url = url.deletingPathExtension().appendingPathExtension(SafetyCopy.fileExtension)
    // Private from the first byte: only the user's own account may read a recording.
    descriptor = open(self.url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return nil }
    guard put(SafetyCopy.header(soundBytes: 0), at: 0) else {
      remove()
      return nil
    }
  }

  deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

  /// Adds samples. When the disk is full the copy stops growing; what it holds stays readable.
  func write(_ samples: UnsafeBufferPointer<Float>) {
    guard descriptor >= 0, let base = samples.baseAddress, !samples.isEmpty else { return }
    var scaled = [Float](repeating: 0, count: samples.count)
    var whole = [Int16](repeating: 0, count: samples.count)
    var (low, high, gain) = (Float(-1), Float(1), Float(Int16.max))
    let count = vDSP_Length(samples.count)
    vDSP_vclip(base, 1, &low, &high, &scaled, 1, count)
    vDSP_vsmul(scaled, 1, &gain, &scaled, 1, count)
    vDSP_vfixr16(scaled, 1, &whole, 1, count)

    // `Int16` is stored low byte first on every device Apple makes, as the format wants.
    let sound = whole.withUnsafeBytes { Data($0) }
    guard put(sound, at: SafetyCopy.headerSize + bytes) else {
      Darwin.close(descriptor)
      descriptor = -1
      return
    }
    bytes += sound.count
    // The sound goes in before the header says so: a header never promises more than is there.
    _ = put(SafetyCopy.header(soundBytes: bytes), at: 0)
  }

  /// Deletes the copy.
  func remove() {
    if descriptor >= 0 { Darwin.close(descriptor) }
    descriptor = -1
    unlink(url.path)
  }

  private func put(_ data: Data, at offset: Int) -> Bool {
    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
      guard let base = buffer.baseAddress else { return true }
      var done = 0
      while done < buffer.count {
        let written = pwrite(descriptor, base + done, buffer.count - done, off_t(offset + done))
        if written > 0 {
          done += written
        } else if errno != EINTR {
          return false
        }
      }
      return true
    }
  }

  private static let headerSize = 44

  /// The 44 bytes that start a `.wav` file holding `soundBytes` bytes of sound.
  private static func header(soundBytes: Int) -> Data {
    var data = Data()
    func add(_ text: String) { data.append(contentsOf: text.utf8) }
    func add32(_ value: Int) {
      withUnsafeBytes(of: UInt32(clamping: value).littleEndian) { data.append(contentsOf: $0) }
    }
    func add16(_ value: Int) {
      withUnsafeBytes(of: UInt16(clamping: value).littleEndian) { data.append(contentsOf: $0) }
    }
    let rate = Int(Encoding.sampleRate)
    add("RIFF")
    add32(headerSize - 8 + soundBytes)
    add("WAVE")
    add("fmt ")
    add32(16)
    // Plain whole-number samples, one channel.
    add16(1)
    add16(1)
    add32(rate)
    // Bytes a second, bytes a sample, bits a sample.
    add32(rate * 2)
    add16(2)
    add16(16)
    add("data")
    add32(soundBytes)
    return data
  }
}
