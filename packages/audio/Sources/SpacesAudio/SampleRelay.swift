import CoreAudio
import CoreMedia

/// Carries sound off the real-time audio thread without locks or allocation.
///
/// The audio thread calls `write`; one ordinary thread calls `drain`. All
/// memory is set aside up front as fixed-size blocks. Two lock-free queues
/// pass the blocks round: empty ones to the writer, filled ones to the
/// reader. When the reader falls too far behind, new sound is dropped rather
/// than making the audio thread wait.
///
/// `@unchecked Sendable`: the only shared state is the two `CMSimpleQueue`s,
/// which Core Media documents as safe for one enqueuing and one dequeuing
/// thread each. That is exactly how they are used: the audio thread takes
/// from `empty` and adds to `filled`; the reader does the reverse. A block
/// is touched only by the thread that currently holds it.
final class SampleRelay: @unchecked Sendable {
  /// What sits in front of the samples in each block.
  private struct Header {
    var hostTime: UInt64
    var frames: Int32
    /// Frames into the audio thread's buffer this block starts at.
    var offset: Int32
  }

  let blockFrames: Int
  private let stride: Int
  private let memory: UnsafeMutableRawPointer
  private let empty: CMSimpleQueue
  private let filled: CMSimpleQueue

  /// - Parameters:
  ///   - blocks: How many blocks to set aside.
  ///   - blockFrames: Samples per block.
  init?(blocks: Int = 512, blockFrames: Int = 1_024) {
    var first: CMSimpleQueue?
    var second: CMSimpleQueue?
    guard blocks > 0, blockFrames > 0,
      CMSimpleQueueCreate(allocator: kCFAllocatorDefault, capacity: Int32(blocks), queueOut: &first)
        == noErr,
      CMSimpleQueueCreate(allocator: kCFAllocatorDefault, capacity: Int32(blocks), queueOut: &second)
        == noErr,
      let first, let second
    else { return nil }
    empty = first
    filled = second
    self.blockFrames = blockFrames
    stride = MemoryLayout<Header>.stride + blockFrames * MemoryLayout<Float>.stride
    memory = UnsafeMutableRawPointer.allocate(
      byteCount: stride * blocks,
      alignment: MemoryLayout<Header>.alignment
    )
    for index in 0..<blocks {
      CMSimpleQueueEnqueue(empty, element: memory + index * stride)
    }
  }

  deinit { memory.deallocate() }

  /// Mixes `list` (32-bit float, any channel layout) down to mono and queues it.
  ///
  /// Safe on the real-time audio thread: no locks, no allocation, no calls
  /// that can wait.
  ///
  /// - Returns: `false` when some of the sound was dropped because the reader
  ///   has fallen too far behind.
  @discardableResult
  func write(_ list: UnsafePointer<AudioBufferList>, hostTime: UInt64) -> Bool {
    // Plain counted loops on purpose: nothing here may allocate or wait.
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    let bufferCount = buffers.count
    var channels = 0
    var frames = Int.max
    var index = 0
    while index < bufferCount {
      let buffer = buffers[index]
      index += 1
      let width = Int(buffer.mNumberChannels)
      if width == 0 || buffer.mData == nil { continue }
      channels += width
      frames = min(frames, Int(buffer.mDataByteSize) / (width * MemoryLayout<Float>.stride))
    }
    guard channels > 0, frames > 0, frames != Int.max else { return true }
    let gain = 1 / Float(channels)

    var done = 0
    while done < frames {
      // No empty block: the reader is far behind. Drop the rest.
      guard let taken = CMSimpleQueueDequeue(empty) else { return false }
      let block = UnsafeMutableRawPointer(mutating: taken)
      let count = min(blockFrames, frames - done)
      let samples = (block + MemoryLayout<Header>.stride).assumingMemoryBound(to: Float.self)
      samples.update(repeating: 0, count: count)
      index = 0
      while index < bufferCount {
        let buffer = buffers[index]
        index += 1
        let width = Int(buffer.mNumberChannels)
        guard width > 0, let data = buffer.mData else { continue }
        let source = data.assumingMemoryBound(to: Float.self) + done * width
        var frame = 0
        while frame < count {
          var sum: Float = 0
          var channel = 0
          while channel < width {
            sum += source[frame * width + channel]
            channel += 1
          }
          samples[frame] += sum * gain
          frame += 1
        }
      }
      block.storeBytes(
        of: Header(hostTime: hostTime, frames: Int32(count), offset: Int32(done)),
        as: Header.self
      )
      CMSimpleQueueEnqueue(filled, element: block)
      done += count
    }
    return true
  }

  /// Hands every queued block to `body`, oldest first.
  ///
  /// - Parameter body: Gets the mono samples, the host time of the audio
  ///   thread's buffer they came from, and how many frames into that buffer
  ///   they start. The samples are only valid during the call.
  func drain(_ body: (UnsafeBufferPointer<Float>, _ hostTime: UInt64, _ offset: Int) -> Void) {
    while let taken = CMSimpleQueueDequeue(filled) {
      let header = taken.load(as: Header.self)
      let samples = (taken + MemoryLayout<Header>.stride).assumingMemoryBound(to: Float.self)
      body(
        UnsafeBufferPointer(start: samples, count: Int(header.frames)),
        header.hostTime,
        Int(header.offset)
      )
      CMSimpleQueueEnqueue(empty, element: taken)
    }
  }
}
