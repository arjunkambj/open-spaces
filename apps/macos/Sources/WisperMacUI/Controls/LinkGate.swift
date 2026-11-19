import Foundation
import WisperDomain

/// Decides what to do with an `openwisper://` link.
///
/// Anything on the Mac can open a link: a web page, a document, a message.
/// So a link that makes the app listen, or cuts a recording short, is only
/// followed without a question when it carries a valid `LinkTicket` (the
/// bundled `wisper` tool attaches one).
///
/// ```swift
/// switch gate.decide(link, ticketIsValid: redeemed, isSetUp: ..., isRecordingMeeting: ...) {
/// case .act: ...                       // do what the link says
/// case .ask: ...                       // ask the person, then call `answered(allowed:)`
/// case .ignore: break
/// }
/// ```
public struct LinkGate: Sendable {
  public enum Decision: Equatable, Sendable {
    /// Do what the link says, now.
    case act
    /// Ask the person first, and act only on yes. Call `answered(allowed:)` when they have chosen.
    case ask
    case ignore
  }

  /// How long questions stay away after the person said no, in seconds.
  public static let quietTime: TimeInterval = 60

  private var isAsking = false
  private var quietUntil = Date.distantPast

  public init() {}

  /// - ticketIsValid: the link's ticket was redeemed just now (`LinkTicket.redeem`).
  /// - isSetUp: the library has been read and first-run setup is finished.
  /// - isRecordingMeeting: a meeting is being recorded right now.
  ///
  /// What a caller can rely on:
  /// - Nothing is followed before setup is finished.
  /// - Links that only show something are always followed.
  /// - Without a ticket, dictation is never started and a recording is never stopped.
  /// - Without a ticket, starting a meeting needs a yes from the person. Only one question is
  ///   open at a time, and after a no there are none for `quietTime`: a page cannot fill the
  ///   screen with dialogs.
  public mutating func decide(
    _ link: WisperLink,
    ticketIsValid: Bool,
    isSetUp: Bool,
    isRecordingMeeting: Bool,
    now: Date = Date()
  ) -> Decision {
    guard isSetUp else { return .ignore }
    guard link.needsTrust, !ticketIsValid else { return .act }
    switch link {
    case .startMeeting:
      guard !isRecordingMeeting, !isAsking, now >= quietUntil else { return .ignore }
      isAsking = true
      return .ask
    case .toggleDictation, .stopMeeting, .showMeeting, .showHub:
      return .ignore
    }
  }

  /// The person answered the question that `decide` asked for.
  public mutating func answered(allowed: Bool, now: Date = Date()) {
    isAsking = false
    if !allowed { quietUntil = now.addingTimeInterval(Self.quietTime) }
  }
}
