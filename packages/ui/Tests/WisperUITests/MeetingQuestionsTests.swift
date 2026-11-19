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

  // MARK: Kept for the session, and capped

  @Test func theSessionKeepsAThreadWhileTheScreenIsGone() async {
    let gate = Gate()
    let (engine, id) = engine { _ in
      await gate.wait()
      return "On the 14th."
    }
    // The hub builds the Meetings screen again on every visit. Each one reads the same store.
    let session = MeetingQuestions.session
    let asking = Task { await session.ask("When do we ship?", about: id, with: engine) }
    while !session.isWaiting(for: id) { await Task.yield() }
    // The screen goes away here, and the answer arrives while it is not showing.
    await gate.open()
    await asking.value
    // The screen that is built next finds the question and its answer.
    #expect(MeetingQuestions.session.thread(for: id).map(\.question) == ["When do we ship?"])
    #expect(MeetingQuestions.session.thread(for: id).map(\.reply) == [.answer("On the 14th.")])
  }

  @Test func keepsOnlyTheNewestQuestionsOfAThread() async {
    let (engine, id) = engine { _ in "Yes." }
    let questions = MeetingQuestions(questionLimit: 3)
    for number in 1...5 { await questions.ask("Question \(number)?", about: id, with: engine) }
    #expect(questions.thread(for: id).map(\.question) == ["Question 3?", "Question 4?", "Question 5?"])
  }

  @Test func keepsOnlyTheThreadsAskedAboutLast() async {
    let (engine, first) = engine { _ in "Yes." }
    let (second, third) = (UUID(), UUID())
    let questions = MeetingQuestions(meetingLimit: 2)
    await questions.ask("One?", about: first, with: engine)
    await questions.ask("Two?", about: second, with: engine)
    // Asking about the first again makes the second the one asked about longest ago.
    await questions.ask("One more?", about: first, with: engine)
    await questions.ask("Three?", about: third, with: engine)
    #expect(questions.thread(for: first).count == 2)
    #expect(questions.thread(for: second).isEmpty)
    #expect(questions.thread(for: third).count == 1)
  }

  @Test func neverDropsAThreadThatIsWaitingForItsAnswer() async {
    let gate = Gate()
    let (engine, slow) = engine { request in
      if request.user.contains("Slow?") { await gate.wait() }
      return "Done."
    }
    let questions = MeetingQuestions(meetingLimit: 1)
    let waiting = Task { await questions.ask("Slow?", about: slow, with: engine) }
    while !questions.isWaiting(for: slow) { await Task.yield() }
    await questions.ask("Quick?", about: UUID(), with: engine)
    #expect(questions.thread(for: slow).map(\.reply) == [.waiting])
    await gate.open()
    await waiting.value
    #expect(questions.thread(for: slow).map(\.reply) == [.answer("Done.")])
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
