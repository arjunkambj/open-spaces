import AVFoundation
import WisperDomain

/// Records the microphone and, on macOS, what the computer is playing.
///
/// Files are AAC in `.m4a`, mono, 16 kHz, named `<track>-<4-digit number>.m4a`
/// in the request's folder. Each one is closed and playable when it is emitted.
///
/// - Offsets of both tracks are measured on one clock, from the moment
///   `start` was called, so the two tracks line up.
/// - With `chunkSeconds` set, a file is cut at a pause in the sound near that
///   length when there is one, and after at most 20% (3 seconds at most) more
///   when there is not. Stretches with no signal at all (nothing is playing,
///   or the microphone is muted) are left out, so a track that stays silent
///   produces no files, and a file's `offset` says where its sound starts.
/// - With `chunkSeconds == nil` there is exactly one file per track after
///   `stop()`, even when it holds only silence.
/// - `start` never shows a permission prompt. It throws
///   `WisperError.permissionDenied(.microphone)` unless microphone access was
///   already granted.
/// - On iOS the `.system` track is not available and asking for it throws
///   `WisperError.captureFailed`.
public struct SystemAudioCapture: AudioCapture {
  public init() {}

  public func microphones() async -> [AudioDevice] {
    MicrophoneSource.devices()
  }

  public func start(_ request: CaptureRequest) async throws -> any CaptureSession {
    guard !request.tracks.isEmpty else {
      throw WisperError.captureFailed("Nothing was chosen to record.")
    }
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: request.directory.path, isDirectory: &isFolder),
      isFolder.boolValue, FileManager.default.isWritableFile(atPath: request.directory.path)
    else {
      throw WisperError.captureFailed("The folder for the recording is missing.")
    }

    var sources: [AudioTrack: any AudioSource] = [:]
    if request.tracks.contains(.system) {
      #if os(macOS)
        sources[.system] = SystemTapSource()
      #else
        throw WisperError.captureFailed("iPhone and iPad cannot record the sound of other apps.")
      #endif
    }
    if request.tracks.contains(.microphone) {
      // Reading the status never prompts. Asking is the `Permissions` seam's job.
      guard AVAudioApplication.shared.recordPermission == .granted else {
        throw WisperError.permissionDenied(.microphone)
      }
      sources[.microphone] = MicrophoneSource(deviceID: request.microphoneID)
    }

    // Starting audio hardware can take a few hundred milliseconds. Keep that
    // off the caller's thread and off Swift's shared thread pool.
    let ready = sources
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          with: Result { try Recording.start(request, sources: ready) as any CaptureSession }
        )
      }
    }
  }
}
