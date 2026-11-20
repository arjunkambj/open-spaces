import Accelerate
import Foundation

/// Changes mono samples from one sample rate to 16 kHz, a buffer at a time.
///
/// A windowed-sinc filter, written here instead of using `AVAudioConverter`
/// because that converter keeps back a changing amount of sound between calls
/// (up to 80 ms with the 100 ms buffers a Mac microphone delivers), which
/// would smear file start times. This one always returns every output sample
/// it can, and holds back only one millisecond.
///
/// Anything above 7.2 kHz is removed before the rate is lowered, so high
/// sounds do not fold back into the speech range.
struct Resampler {
  let inputRate: Double

  /// Filter positions stored per input sample.
  private static let resolution = 512
  /// How many ripples of the filter are kept on each side.
  private static let ripples = 16

  /// Input samples per output sample.
  private let step: Double
  /// Filter reach in input samples, each side.
  private let reach: Int
  /// The filter, from `-reach` to `+reach`, `resolution` points per input sample.
  private let filter: [Float]
  /// Makes each filter position add up to exactly 1, so loudness is kept.
  private let gain: [Float]
  /// Input not fully used yet. Begins with `reach` samples of silence.
  private var pending: [Float]
  /// Input samples taken in so far.
  private var received = 0
  /// Input samples already dropped from the front of `pending`.
  private var dropped = 0
  /// Output samples made so far. Output `n` sits at input sample `n * step`,
  /// worked out afresh each time so that small rounding errors cannot add up.
  private var produced = 0

  init(inputRate: Double) {
    self.inputRate = inputRate
    step = inputRate / Encoding.sampleRate
    let resolution = Resampler.resolution
    // Pass band as a share of the input rate: 45% of the lower of the two rates.
    let cutoff = 0.45 * min(1, Encoding.sampleRate / inputRate)
    let reach = Int((Double(Resampler.ripples) * max(1, step)).rounded(.up))
    self.reach = reach

    var filter = [Float](repeating: 0, count: 2 * reach * resolution + 1)
    for index in filter.indices {
      let time = Double(index) / Double(resolution) - Double(reach)
      let angle = 2 * Double.pi * cutoff * time
      let sinc = time == 0 ? 1 : sin(angle) / angle
      // A Blackman window fades the filter out smoothly at both ends.
      let edge = time / Double(reach)
      let window = 0.42 + 0.5 * cos(Double.pi * edge) + 0.08 * cos(2 * Double.pi * edge)
      filter[index] = Float(2 * cutoff * sinc * window)
    }
    self.filter = filter

    var gain = [Float](repeating: 1, count: resolution + 1)
    for shift in 0...resolution {
      var sum: Float = 0
      for tap in 0..<2 * reach { sum += filter[(tap + 1) * resolution - shift] }
      gain[shift] = sum == 0 ? 1 : 1 / sum
    }
    self.gain = gain

    pending = [Float](repeating: 0, count: reach)
  }

  /// Returns the 16 kHz samples that `samples` completes.
  mutating func convert(_ samples: [Float]) -> [Float] {
    if step == 1 { return samples }
    pending.append(contentsOf: samples)
    received += samples.count
    return produce(upTo: Int.max)
  }

  /// Returns the last samples, as if silence followed. The resampler is used up afterwards.
  mutating func finish() -> [Float] {
    if step == 1 { return [] }
    // One output is owed for every `step` input samples given. The small
    // allowance keeps a rounding error from adding a sample.
    let owed = Int((Double(received) / step - 1e-9).rounded(.up))
    pending.append(contentsOf: [Float](repeating: 0, count: reach + 1))
    return produce(upTo: owed)
  }

  /// Makes output samples until the input runs short or `limit` have been made in all.
  private mutating func produce(upTo limit: Int) -> [Float] {
    let taps = 2 * reach
    let resolution = Resampler.resolution
    var output: [Float] = []
    output.reserveCapacity(Int(Double(pending.count) / step) + 1)
    pending.withUnsafeBufferPointer { input in
      filter.withUnsafeBufferPointer { filter in
        guard let samples = input.baseAddress, let weights = filter.baseAddress else { return }
        while produced < limit {
          // `pending[0]` is input sample `dropped - reach`.
          let place = Double(produced) * step
          let whole = place.rounded(.down)
          let base = Int(whole) - dropped + reach
          // The filter needs `reach` samples either side of the output's place.
          guard base + reach < input.count else { break }
          let shift = min(resolution, max(0, Int(((place - whole) * Double(resolution)).rounded())))
          var value: Float = 0
          vDSP_dotpr(
            samples + (base - reach + 1),
            1,
            weights + (resolution - shift),
            vDSP_Stride(resolution),
            &value,
            vDSP_Length(taps)
          )
          output.append(value * gain[shift])
          produced += 1
        }
      }
    }
    // Drop the input that no later output can reach.
    let next = Int((Double(produced) * step).rounded(.down)) - dropped + reach
    let used = min(pending.count, max(0, next - reach + 1))
    if used > 0 {
      pending.removeFirst(used)
      dropped += used
    }
    return output
  }
}
