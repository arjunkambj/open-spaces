import Foundation
import Testing
import WisperDomain

@testable import WisperMacUI

@Suite struct LinkGateTests {
  private let now = Date(timeIntervalSinceReferenceDate: 1000)
  private let meetingID = UUID()

  private func decide(
    _ gate: inout LinkGate,
    _ link: WisperLink,
    ticket: Bool = false,
    isSetUp: Bool = true,
    isRecordingMeeting: Bool = false,
    after seconds: TimeInterval = 0
  ) -> LinkGate.Decision {
    gate.decide(
      link,
      ticketIsValid: ticket,
      isSetUp: isSetUp,
      isRecordingMeeting: isRecordingMeeting,
      now: now.addingTimeInterval(seconds)
    )
  }

  private var everyLink: [WisperLink] {
    [.showHub, .showMeeting(meetingID), .toggleDictation, .startMeeting(title: "Standup"), .stopMeeting]
  }

  @Test func nothingIsFollowedBeforeSetupIsDone() {
    for link in everyLink {
      for ticket in [false, true] {
        var gate = LinkGate()
        #expect(decide(&gate, link, ticket: ticket, isSetUp: false) == .ignore, "\(link)")
      }
    }
  }

  @Test func linksThatOnlyShowSomethingAreFollowed() {
    var gate = LinkGate()
    #expect(decide(&gate, .showHub) == .act)
    #expect(decide(&gate, .showMeeting(meetingID)) == .act)
  }

  @Test func aLinkWithAGoodTicketIsFollowedAtOnce() {
    for link in everyLink {
      var gate = LinkGate()
      #expect(decide(&gate, link, ticket: true) == .act, "\(link)")
    }
  }

  @Test func withoutATicketDictationIsNeverStartedAndARecordingNeverStopped() {
    var gate = LinkGate()
    #expect(decide(&gate, .toggleDictation) == .ignore)
    #expect(decide(&gate, .stopMeeting) == .ignore)
    #expect(decide(&gate, .stopMeeting, isRecordingMeeting: true) == .ignore)
  }

  @Test func withoutATicketStartingAMeetingIsAskedAbout() {
    var gate = LinkGate()
    #expect(decide(&gate, .startMeeting(title: nil)) == .ask)
  }

  @Test func thereIsNothingToAskWhileAMeetingIsBeingRecorded() {
    var gate = LinkGate()
    #expect(decide(&gate, .startMeeting(title: nil), isRecordingMeeting: true) == .ignore)
  }

  @Test func onlyOneQuestionIsOpenAtATime() {
    var gate = LinkGate()
    #expect(decide(&gate, .startMeeting(title: "One")) == .ask)
    #expect(decide(&gate, .startMeeting(title: "Two")) == .ignore)
    #expect(decide(&gate, .startMeeting(title: "Three"), after: 600) == .ignore)
    // A ticketed link is not held up by an open question.
    #expect(decide(&gate, .startMeeting(title: "Four"), ticket: true) == .act)
    gate.answered(allowed: true, now: now)
    #expect(decide(&gate, .startMeeting(title: "Five")) == .ask)
  }

  @Test func afterANoThereAreNoQuestionsForAWhile() {
    var gate = LinkGate()
    #expect(decide(&gate, .startMeeting(title: nil)) == .ask)
    gate.answered(allowed: false, now: now)
    #expect(decide(&gate, .startMeeting(title: nil), after: 1) == .ignore)
    #expect(decide(&gate, .startMeeting(title: nil), after: LinkGate.quietTime - 1) == .ignore)
    #expect(decide(&gate, .startMeeting(title: nil), after: LinkGate.quietTime) == .ask)
  }
}
