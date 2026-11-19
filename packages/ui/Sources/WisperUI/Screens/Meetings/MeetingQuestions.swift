import Foundation
import Observation
import WisperDomain
import WisperEngine

/// The questions asked about meetings since the screen was opened, with their answers.
/// Nothing here is saved: the thread is gone when the app quits.
@MainActor
@Observable
final class MeetingQuestions {
  struct Entry: Identifiable, Equatable, Sendable {
    enum Reply: Equatable, Sendable {
      case waiting
      case answer(String)
      /// The reason, in plain English.
      case failed(String)
    }

    var id = UUID()
    var question: String
    var reply: Reply = .waiting
  }

  private var threads: [Meeting.ID: [Entry]]

  init(threads: [Meeting.ID: [Entry]] = [:]) {
    self.threads = threads
  }

  /// The questions about one meeting, oldest first.
  func thread(for meeting: Meeting.ID) -> [Entry] {
    threads[meeting] ?? []
  }

  /// Whether an answer about this meeting is on its way.
  func isWaiting(for meeting: Meeting.ID) -> Bool {
    thread(for: meeting).contains { $0.reply == .waiting }
  }

  /// Asks the question and keeps the answer, or the reason there is none.
  /// Does nothing for an empty question, or while another answer is on its way.
  func ask(_ question: String, about meeting: Meeting.ID, with engine: MeetingEngine) async {
    let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, !isWaiting(for: meeting) else { return }
    let entry = Entry(question: question)
    threads[meeting, default: []].append(entry)
    await answer(entry.id, about: meeting, with: engine)
  }

  /// Asks a question again that got no answer.
  func askAgain(_ entry: Entry.ID, about meeting: Meeting.ID, with engine: MeetingEngine) async {
    guard !isWaiting(for: meeting),
      let index = threads[meeting]?.firstIndex(where: { $0.id == entry }),
      case .failed = threads[meeting]?[index].reply
    else { return }
    threads[meeting]?[index].reply = .waiting
    await answer(entry, about: meeting, with: engine)
  }

  private func answer(_ entry: Entry.ID, about meeting: Meeting.ID, with engine: MeetingEngine) async {
    guard let question = threads[meeting]?.first(where: { $0.id == entry })?.question else { return }
    let reply: Entry.Reply
    do {
      let text = try await engine.ask(question, about: meeting)
      reply = .answer(text.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
      reply = .failed(error.localizedDescription)
    }
    guard let index = threads[meeting]?.firstIndex(where: { $0.id == entry }) else { return }
    threads[meeting]?[index].reply = reply
  }
}
