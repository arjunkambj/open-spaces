import Foundation
import Testing
import WisperDomain
import WisperEngine

@testable import WisperUI

@Suite("Meetings: questions about a meeting")
@MainActor
struct MeetingQuestionsTests {
  /// An engine over a library that holds one meeting with a transcript.
  private func engine(
    answering reply: @escaping @Sendable (CompletionRequest) async throws -> String
  ) -> (MeetingEngine, Meeting.ID) {
    let meeting = Meeting(
      title: "Sync",
      status: .ready,
      segments: [TranscriptSegment(speaker: .me, start: 0, end: 4, text: "We ship on the 14th.")]
    )
    let engine = MeetingEngine(
      library: InMemoryLibrary(meetings: [meeting]),
      capture: FakeAudioCapture(),
      transcriber: FakeTranscriber(text: ""),
      languageModel: FakeLanguageModel(reply: reply)
    )
    return (engine, meeting.id)
  }

  @Test func keepsTheAnswerUnderItsQuestion() async {
    let (engine, id) = engine { _ in " On the 14th.\n" }
    let questions = MeetingQuestions()
    await questions.ask("  When do we ship? ", about: id, with: engine)
    let thread = questions.thread(for: id)
    #expect(thread.map(\.question) == ["When do we ship?"])
    #expect(thread.map(\.reply) == [.answer("On the 14th.")])
    #expect(!questions.isWaiting(for: id))
  }

  @Test func keepsQuestionsInTheOrderAskedAndApartByMeeting() async {
    let (engine, id) = engine { _ in "Yes." }
    let questions = MeetingQuestions()
    await questions.ask("First?", about: id, with: engine)
    await questions.ask("Second?", about: id, with: engine)
    #expect(questions.thread(for: id).map(\.question) == ["First?", "Second?"])
    #expect(questions.thread(for: UUID()).isEmpty)
  }

  @Test func ignoresAnEmptyQuestion() async {
    let (engine, id) = engine { _ in "Yes." }
    let questions = MeetingQuestions()
    await questions.ask("   ", about: id, with: engine)
    #expect(questions.thread(for: id).isEmpty)
  }

  @Test func showsWhyThereIsNoAnswer() async {
    let (engine, id) = engine { _ in throw WisperError.rateLimited }
    let questions = MeetingQuestions()
    await questions.ask("When do we ship?", about: id, with: engine)
    #expect(questions.thread(for: id).map(\.reply) == [.failed(WisperError.rateLimited.localizedDescription)])
  }

  @Test func asksAgainInPlaceAfterAFailure() async {
    let attempts = Attempts()
    let (engine, id) = engine { _ in
      if await attempts.next() == 1 { throw WisperError.rateLimited }
      return "On the 14th."
    }
    let questions = MeetingQuestions()
    await questions.ask("When do we ship?", about: id, with: engine)
    guard let entry = questions.thread(for: id).first else {
      Issue.record("The question was not kept.")
      return
    }
    await questions.askAgain(entry.id, about: id, with: engine)
    #expect(
      questions.thread(for: id) == [
        .init(id: entry.id, question: "When do we ship?", reply: .answer("On the 14th."))
      ]
    )
  }

  @Test func doesNotAskAgainWhatWasAnswered() async {
    let attempts = Attempts()
    let (engine, id) = engine { _ in "Answer \(await attempts.next())" }
    let questions = MeetingQuestions()
    await questions.ask("When do we ship?", about: id, with: engine)
    guard let entry = questions.thread(for: id).first else {
      Issue.record("The question was not kept.")
      return
    }
    await questions.askAgain(entry.id, about: id, with: engine)
    #expect(questions.thread(for: id).map(\.reply) == [.answer("Answer 1")])
  }

  @Test func takesOneQuestionAtATimePerMeeting() async {
    let gate = Gate()
    let (engine, id) = engine { _ in
      await gate.wait()
      return "Done."
    }
    let questions = MeetingQuestions()
    let first = Task { await questions.ask("First?", about: id, with: engine) }
    while !questions.isWaiting(for: id) { await Task.yield() }
    await questions.ask("Second?", about: id, with: engine)
    #expect(questions.thread(for: id).map(\.question) == ["First?"])
    #expect(questions.thread(for: id).first?.reply == .waiting)
    await gate.open()
    await first.value
    #expect(questions.thread(for: id).map(\.reply) == [.answer("Done.")])
  }
}

/// Counts calls.
private actor Attempts {
  private var count = 0

  func next() -> Int {
    count += 1
    return count
  }
}

/// Holds callers until it is opened.
private actor Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}
