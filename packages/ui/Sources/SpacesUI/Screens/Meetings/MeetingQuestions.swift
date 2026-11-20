import Foundation
import Observation
import SpacesDomain
import SpacesEngine

/// The questions asked about meetings, with their answers.
/// Nothing here is saved: the threads are gone when the app quits.
@MainActor
@Observable
final class MeetingQuestions {
  /// The threads of this run of the app. They outlive the Meetings screen, which the hub builds
  /// again each time its section is chosen, so a thread is still there on the way back, with
  /// any answer that came in meanwhile.
  static let session = MeetingQuestions()

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
  /// The meetings with a thread, the one asked about last at the end.
  private var recent: [Meeting.ID]

  /// How many meetings keep a thread. The ones asked about longest ago go first.
  private let meetingLimit = 20
  /// How many questions a thread keeps. The oldest go first.
  private let questionLimit = 50

  init(threads: [Meeting.ID: [Entry]] = [:]) {
    self.threads = threads
    recent = Array(threads.keys)
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
    trim(keeping: meeting)
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

  /// Keeps what is held small: the newest questions of a thread, and the threads asked about last.
  /// A thread that is waiting for an answer is never dropped.
  private func trim(keeping meeting: Meeting.ID) {
    if let count = threads[meeting]?.count, count > questionLimit {
      threads[meeting]?.removeFirst(count - questionLimit)
    }
    recent.removeAll { $0 == meeting }
    recent.append(meeting)
    var extra = recent.count - meetingLimit
    for old in recent where extra > 0 && old != meeting && !isWaiting(for: old) {
      threads[old] = nil
      extra -= 1
    }
    recent.removeAll { threads[$0] == nil }
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
