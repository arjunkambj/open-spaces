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

  /// - Parameter expectedSeconds: About how long the file will be. A longer
  ///   file is still valid; its index just lands at the end instead of the front.
  init?(url: URL, expectedSeconds: Double) {
    self.url = url
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
    let flags = AudioFileFlags.eraseFile.rawValue
    guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &format, nil, flags, &file) == noErr,
      let file
    else { return nil }

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
  }

  /// Closes the file and deletes it.
  func remove() {
    close()
    try? FileManager.default.removeItem(at: url)
  }
}
