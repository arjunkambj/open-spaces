import Foundation
import Testing
import WisperDomain
import WisperStore

@testable import WisperEngine

/// What happens to a meeting's audio when things go wrong, on the real file library with real
/// audio files: a meeting's audio is never deleted unless it was transcribed or the user deleted
/// the meeting, and a meeting never looks complete when part of it was lost.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MeetingRecoveryTests {
  private static let lostPart =
    "The app closed while this meeting was being recorded. The last part could not be saved."

  /// The four audio files of a meeting the app quit in the middle of, two seconds each.
  private static let fourFiles = (0..<4).map { "microphone-000\($0).m4a" }

  private func permissions(_ url: URL) throws -> Int {
    try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
  }

  // MARK: The manifest is not there to be trusted

  enum Record: CaseIterable, Sendable {
    /// Cut off in the middle of a write.
    case cutOff
    case missing
    /// Not JSON at all.
    case damaged
    /// Readable, and behind: it knows the first file only, and that it was transcribed.
    case behind

    var data: Data? {
      switch self {
      case .cutOff: Data(#"{"version":1,"chunks":[{"file":"microphone-0000.m4a""#.utf8)
      case .missing: nil
      case .damaged: Data("\0\0\0 not a record".utf8)
      case .behind:
        Data(
          """
          {"version":1,"chunks":[{"file":"microphone-0000.m4a","track":"microphone","offset":0,
          "duration":2,"state":"done","segments":[]}]}
          """.utf8
        )
      }
    }
  }

  @Test(arguments: Record.allCases, [true, false])
  func aMeetingIsFinishedFromItsAudioFilesWhateverTheRecordSays(record: Record, keepAudio: Bool) async throws {
    let rig = try await MeetingDiskRig(keepAudio: keepAudio)
    let (meeting, audio) = try await rig.interruptedMeeting()
    for name in Self.fourFiles { try MeetingAudio.writeM4A(2, to: audio.appendingPathComponent(name)) }
    try record.data?.write(to: audio.appendingPathComponent(MeetingManifest.fileName))

    await rig.engine.recoverUnfinished()
    let recovered = try await rig.finished(meeting.id)

    // Every file the record did not vouch for went to the transcriber, once.
    let expected = record == .behind ? Array(Self.fourFiles.dropFirst()) : Self.fourFiles
    #expect(rig.transcribed == expected)
    #expect(recovered.status == .ready)
    #expect(recovered.failure == nil)
    #expect(recovered.segments.map(\.text) == expected.map { "Said in \($0)." })
    #expect(recovered.segments.allSatisfy { $0.speaker == .me })
    // Each file follows the one before it on its track, by the lengths of the files themselves.
    let starts = recovered.segments.map(\.start)
    let firstStart = record == .behind ? 2.0 : 0.0
    for (index, start) in starts.enumerated() { #expect(abs(start - (firstStart + Double(index) * 2)) < 0.3) }
    let length = try #require(recovered.endedAt).timeIntervalSince(recovered.startedAt)
    #expect(abs(length - 8) < 0.5)
    #expect(recovered.notes != nil)

    if keepAudio {
      #expect(rig.files(in: audio) == [MeetingManifest.fileName] + Self.fourFiles)
      // The record is whole again, and private like the audio.
      let manifest = try #require(rig.manifest(meeting.id))
      #expect(manifest.chunks.map(\.file) == Self.fourFiles)
      #expect(manifest.chunks.allSatisfy { $0.state == .done })
      #expect(try permissions(audio) == 0o700)
      for name in rig.files(in: audio) { #expect(try permissions(audio.appendingPathComponent(name)) == 0o600) }
    } else {
      // Gone, but only now that all of it was transcribed.
      #expect(!FileManager.default.fileExists(atPath: audio.path))
    }
  }

  @Test func audioThatCouldNotBeTranscribedIsKeptEvenWhenAudioIsNotKept() async throws {
    let offline = MeetingSwitch(true)
    let rig = try await MeetingDiskRig(
      keepAudio: false,
      transcriber: FakeTranscriber { request in
        if offline.isOn { throw WisperError.network("offline") }
        return Transcript(text: "Said in \(request.audio.lastPathComponent).")
      }
    )
    let (meeting, audio) = try await rig.interruptedMeeting()
    for name in Self.fourFiles { try MeetingAudio.writeM4A(2, to: audio.appendingPathComponent(name)) }
    try Record.cutOff.data?.write(to: audio.appendingPathComponent(MeetingManifest.fileName))

    await rig.engine.recoverUnfinished()
    let failed = try await rig.finished(meeting.id)
    #expect(failed.status == .failed)
    #expect(failed.failure?.hasPrefix("This meeting could not be transcribed.") == true)
    #expect(rig.files(in: audio).filter { $0.hasSuffix(".m4a") } == Self.fourFiles)

    // The connection is back: the same files are used, and only then do they go.
    offline.set(false)
    try await rig.engine.retry(meeting.id)
    let recovered = try await rig.meeting(meeting.id)
    #expect(recovered.status == .ready)
    #expect(recovered.failure == nil)
    #expect(recovered.segments.count == 4)
    #expect(!FileManager.default.fileExists(atPath: audio.path))
  }

  // MARK: The file that was being written when the app closed

  @Test func aFileThatWasNeverClosedIsReadFromItsCopy() async throws {
    // Killed eight seconds into the recording: one file, never closed, and capture's plain copy.
    let rig = try await MeetingDiskRig()
    let (meeting, audio) = try await rig.interruptedMeeting()
    try MeetingAudio.writeUnfinishedM4A(to: audio.appendingPathComponent("microphone-0000.m4a"))
    try MeetingAudio.writeCopy(8, to: audio.appendingPathComponent("microphone-0000.wav"))

    await rig.engine.recoverUnfinished()
    let recovered = try await rig.finished(meeting.id)
    #expect(rig.transcribed == ["microphone-0000.wav"])
    #expect(recovered.status == .ready)
    #expect(recovered.failure == nil)
    #expect(recovered.segments.map(\.text) == ["Said in microphone-0000.wav."])
    let length = try #require(recovered.endedAt).timeIntervalSince(recovered.startedAt)
    #expect(abs(length - 8) < 0.1)
    // The file nobody can read is gone; the copy is this part's audio now.
    #expect(rig.files(in: audio) == [MeetingManifest.fileName, "microphone-0000.wav"])
  }

  @Test func theTailOfALongerMeetingIsReadFromItsCopy() async throws {
    let rig = try await MeetingDiskRig(keepAudio: false)
    let (meeting, audio) = try await rig.interruptedMeeting()
    for track in ["microphone", "system"] {
      try MeetingAudio.writeM4A(2, to: audio.appendingPathComponent("\(track)-0000.m4a"))
      try MeetingAudio.writeUnfinishedM4A(to: audio.appendingPathComponent("\(track)-0001.m4a"))
      try MeetingAudio.writeCopy(3, to: audio.appendingPathComponent("\(track)-0001.wav"))
    }
    // Finished and closed, but the app died before it removed the copy: the copy is not needed.
    try MeetingAudio.writeCopy(2, to: audio.appendingPathComponent("system-0000.wav"))

    await rig.engine.recoverUnfinished()
    let recovered = try await rig.finished(meeting.id)
    #expect(
      rig.transcribed
        == ["microphone-0000.m4a", "microphone-0001.wav", "system-0000.m4a", "system-0001.wav"]
    )
    #expect(recovered.status == .ready)
    #expect(recovered.failure == nil)
    #expect(recovered.segments.count == 4)
    #expect(recovered.segments.map(\.speaker) == [.me, .others, .me, .others])
    #expect(!FileManager.default.fileExists(atPath: audio.path))
  }

  @Test(arguments: [true, false])
  func audioNobodyCanReadIsRemovedAndTheMeetingSaysSo(keepAudio: Bool) async throws {
    let rig = try await MeetingDiskRig(keepAudio: keepAudio)
    let (meeting, audio) = try await rig.interruptedMeeting()
    try MeetingAudio.writeM4A(2, to: audio.appendingPathComponent("microphone-0000.m4a"))
    // Never closed, and with no copy: this part is gone.
    try MeetingAudio.writeUnfinishedM4A(to: audio.appendingPathComponent("microphone-0001.m4a"))

    await rig.engine.recoverUnfinished()
    let recovered = try await rig.finished(meeting.id)
    #expect(rig.transcribed == ["microphone-0000.m4a"])
    #expect(recovered.status == .ready)
    #expect(recovered.segments.map(\.text) == ["Said in microphone-0000.m4a."])
    // Not presented as complete.
    #expect(recovered.failure == Self.lostPart)
    #expect(!rig.files(in: audio).contains("microphone-0001.m4a"))
    #expect(rig.files(in: audio).contains("microphone-0000.m4a") == keepAudio)

    // Trying again cannot bring the part back, and does not make the meeting look whole.
    try await rig.engine.retry(meeting.id)
    #expect(try await rig.meeting(meeting.id) == recovered)
    #expect(rig.transcribed == ["microphone-0000.m4a"])
  }

  @Test func aMeetingKilledInItsFirstSecondsDoesNotComeBackLookingFine() async throws {
    // What an older version left: one file, never closed, no copy.
    let rig = try await MeetingDiskRig()
    let (meeting, audio) = try await rig.interruptedMeeting()
    try MeetingAudio.writeUnfinishedM4A(to: audio.appendingPathComponent("microphone-0000.m4a"))

    await rig.engine.recoverUnfinished()
    let recovered = try await rig.finished(meeting.id)
    #expect(recovered.segments.isEmpty)
    #expect(recovered.failure == Self.lostPart)
    #expect(rig.transcriber.requests.isEmpty)
    #expect(rig.files(in: audio) == [MeetingManifest.fileName])
  }

  @Test func aFileThatStopsShortIsUsedForWhatIsInItAndTheMeetingSaysSo() async throws {
    let rig = try await MeetingDiskRig()
    let (meeting, audio) = try await rig.interruptedMeeting()
    try MeetingAudio.writeM4A(2, to: audio.appendingPathComponent("microphone-0000.m4a"))
    try MeetingAudio.writeM4ACutInHalf(4, to: audio.appendingPathComponent("microphone-0001.m4a"))

    await rig.engine.recoverUnfinished()
    let recovered = try await rig.finished(meeting.id)
    // Half a file is still half a file of what was said.
    #expect(rig.transcribed == ["microphone-0000.m4a", "microphone-0001.m4a"])
    #expect(recovered.segments.count == 2)
    #expect(recovered.failure == Self.lostPart)
    #expect(rig.files(in: audio).contains("microphone-0001.m4a"))
  }

  @Test func aLostPartIsStillSaidOnceTheRestCouldBeTranscribed() async throws {
    let offline = MeetingSwitch(true)
    let rig = try await MeetingDiskRig(
      transcriber: FakeTranscriber { request in
        if offline.isOn { throw WisperError.network("offline") }
        return Transcript(text: "Said in \(request.audio.lastPathComponent).")
      }
    )
    let (meeting, audio) = try await rig.interruptedMeeting()
    try MeetingAudio.writeM4A(2, to: audio.appendingPathComponent("microphone-0000.m4a"))
    try MeetingAudio.writeUnfinishedM4A(to: audio.appendingPathComponent("microphone-0001.m4a"))

    await rig.engine.recoverUnfinished()
    // What can still be put right is said first.
    let failed = try await rig.finished(meeting.id)
    #expect(failed.failure?.hasPrefix("This meeting could not be transcribed.") == true)

    offline.set(false)
    try await rig.engine.retry(meeting.id)
    let recovered = try await rig.meeting(meeting.id)
    #expect(recovered.status == .ready)
    #expect(recovered.segments.count == 1)
    #expect(recovered.failure == Self.lostPart)
  }

  // MARK: A meeting file that cannot be read

  @Test(arguments: [true, false])
  func aDamagedMeetingFileDoesNotCostTheAudio(keepAudio: Bool) async throws {
    let uploading = MeetingGate()
    let release = MeetingGate()
    let rig = try await MeetingDiskRig(
      keepAudio: keepAudio,
      transcriber: FakeTranscriber { request in
        if request.audio.lastPathComponent == "microphone-1.m4a" {
          uploading.open()
          await release.wait()
          throw WisperError.network("offline")
        }
        return Transcript(text: "We agreed on the price.")
      }
    )
    let id = try await rig.engine.start(title: "Pricing")
    let started = try await rig.meeting(id).startedAt
    try #require(rig.capture.sessions.last).emit(duration: 4)
    await rig.engine.stop()
    await uploading.wait()

    // While the upload runs, the meeting's file is damaged.
    try Data("{{{{ broken".utf8).write(to: rig.folder(id).appendingPathComponent("meeting.json"))
    release.open()
    await meetingUntil { rig.engine.processing.isEmpty }

    // The damaged file was moved aside, and nothing else was taken for deleted.
    #expect(rig.files(in: rig.folder(id)).contains { $0.hasPrefix("meeting.json.corrupt-") })
    let audio = rig.files(in: rig.audioFolder(id))
    #expect(audio.contains("microphone-0.m4a") && audio.contains("microphone-1.m4a"))
    // The meeting is back, from what the engine knew of it.
    let meeting = try await rig.meeting(id)
    #expect(meeting.title == "Pricing")
    #expect(meeting.startedAt == started)
    #expect(meeting.endedAt != nil)
    #expect(meeting.segments.map(\.text).contains("We agreed on the price."))
    #expect(meeting.failure?.hasPrefix("Part of this meeting could not be transcribed.") == true)
  }

  @Test func aMeetingFileDamagedWhileRecordingIsWrittenBackOnStop() async throws {
    let rig = try await MeetingDiskRig()
    let id = try await rig.engine.start(title: "Standup")
    try #require(rig.capture.sessions.last).emit(duration: 4)
    await meetingUntil { rig.engine.live?.segments.isEmpty == false }
    try Data("{{{{ broken".utf8).write(to: rig.folder(id).appendingPathComponent("meeting.json"))

    await rig.engine.stop()
    let meeting = try await rig.finished(id)
    #expect(meeting.title != "")
    #expect(meeting.status == .ready)
    #expect(meeting.segments.count == 4)
    #expect(rig.files(in: rig.audioFolder(id)).filter { $0.hasSuffix(".m4a") }.count == 4)
  }

  @Test func aMeetingDeletedWhileItIsProcessedStaysDeleted() async throws {
    let uploading = MeetingGate()
    let release = MeetingGate()
    let rig = try await MeetingDiskRig(
      transcriber: FakeTranscriber { _ in
        uploading.open()
        await release.wait()
        return Transcript(text: "Never mind.")
      }
    )
    let id = try await rig.engine.start()
    await rig.engine.stop()
    await uploading.wait()
    try await rig.library.deleteMeeting(id)
    release.open()
    await meetingUntil { rig.engine.processing.isEmpty }

    #expect(try await rig.library.meeting(id) == nil)
    #expect(try await rig.library.meetings().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: rig.folder(id).appendingPathComponent("meeting.json").path))
    #expect(rig.files(in: rig.audioFolder(id)).isEmpty)
  }

  // MARK: Audio that is not kept

  @Test(arguments: [true, false])
  func audioGoesOnceTheNotesAreWrittenOnASecondTry(keepAudio: Bool) async throws {
    let limited = MeetingSwitch(true)
    let rig = try await MeetingDiskRig(
      keepAudio: keepAudio,
      model: FakeLanguageModel { _ in
        if limited.isOn { throw WisperError.rateLimited }
        return MeetingRig.notesJSON()
      }
    )
    let id = try await rig.engine.start()
    await rig.engine.stop()
    let withoutNotes = try await rig.finished(id)
    #expect(withoutNotes.status == .ready)
    #expect(withoutNotes.failure?.hasPrefix("The notes could not be written.") == true)
    // Kept either way: the meeting is not finished.
    #expect(rig.files(in: rig.audioFolder(id)).contains("microphone-0.m4a"))
    // The record of the audio is as private as the audio.
    let manifest = rig.audioFolder(id).appendingPathComponent(MeetingManifest.fileName)
    #expect(try permissions(manifest) == 0o600)

    limited.set(false)
    try await rig.engine.regenerateNotes(id)
    let meeting = try await rig.meeting(id)
    #expect(meeting.failure == nil)
    #expect(meeting.notes != nil)
    #expect(rig.files(in: rig.audioFolder(id)).contains("microphone-0.m4a") == keepAudio)
    #expect(FileManager.default.fileExists(atPath: rig.audioFolder(id).path) == keepAudio)
  }

  // MARK: A meeting that cannot be saved

  @Test func aMeetingWhoseOutcomeCouldNotBeSavedIsNotLeftProcessing() async throws {
    let library = MeetingFailingLibrary()
    let capture = FakeAudioCapture()
    let full = MeetingSwitch(true)
    let engine = MeetingEngine(
      library: library,
      capture: capture,
      transcriber: MeetingRig.hears(["microphone-0": "Let's ship it."]),
      // The disk fills up after the transcript is saved, while the notes are being written.
      languageModel: FakeLanguageModel { _ in
        if full.isOn { await library.failNextUpdates(1) }
        return MeetingRig.notesJSON()
      },
      tuning: MeetingRig.tuning()
    )
    let id = try await engine.start()
    await engine.stop()
    await meetingUntil { engine.processing.isEmpty }

    let stuck = try #require(try await library.meeting(id))
    #expect(stuck.status == .failed)
    #expect(
      stuck.failure
        == "This meeting could not be saved. " + WisperError.storage("The disk is full.").localizedDescription
    )
    #expect(stuck.segments.map(\.text) == ["Let's ship it."])
    let directory = try await library.audioDirectory(forMeeting: id)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("microphone-0.m4a").path))

    // There is room again.
    full.set(false)
    try await engine.retry(id)
    let meeting = try #require(try await library.meeting(id))
    #expect(meeting.status == .ready)
    #expect(meeting.failure == nil)
    #expect(meeting.notes != nil)
  }
}
