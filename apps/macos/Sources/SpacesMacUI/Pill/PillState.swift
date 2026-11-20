import Foundation
import SpacesDomain
import SpacesEngine

/// What the floating pill shows at one moment. A plain value, worked out from
/// the app's state by `resolve`, so every look can be drawn and tested on its own.
struct PillState: Equatable, Sendable {
  enum Look: Equatable, Sendable {
    /// Nothing is drawn.
    case hidden
    /// The tiny dim capsule.
    case resting
    /// The pointer is over the resting pill: it grows and says how to dictate.
    /// `keys` are the key caps of push to talk; empty when it has no shortcut.
    case hint(keys: [String])
    case recording(mode: DictationMode, handsFree: Bool)
    /// Speech is being turned into text.
    case working
    /// A short message. `canFix` means a click leads somewhere that helps.
    /// `isProblem` is false for plain news ("Copied to the clipboard").
    case notice(String, canFix: Bool, isProblem: Bool = true)
    /// A short message that asks something, with a button for yes and one for no.
    case question(String, yes: String, no: String)
  }

  var look: Look
  /// When the meeting being recorded started, or `nil` when none is.
  var meetingSince: Date?
  /// The shortcuts cannot be heard right now (a password field has the keyboard): the hint says so.
  var shortcutsPaused = false
  /// The pill is being dragged: it is drawn large enough to see under the pointer, and says nothing.
  var isGrabbed = false

  /// Nothing to draw and nothing to click.
  var isEmpty: Bool { look == .hidden && meetingSince == nil }

  /// The pill can be picked up and dragged to another edge. A message cannot: it is gone
  /// in a moment, and its buttons must stay where they are.
  var canMove: Bool {
    switch look {
    case .notice, .question: false
    case .hidden: meetingSince != nil
    case .resting, .hint, .recording, .working: true
    }
  }

  var isRecording: Bool {
    if case .recording = look { return true }
    return false
  }

  /// - showsRecording, isWrappingUp, notice: from `MacControls`.
  /// - isEnabled: the user wants the pill on screen while nothing is going on.
  /// - hintKeys: the key caps of push to talk.
  static func resolve(
    phase: DictationEngine.Phase,
    showsRecording: Bool,
    isWrappingUp: Bool,
    notice: MacControls.Notice?,
    meetingSince: Date?,
    isEnabled: Bool,
    isHovered: Bool,
    hintKeys: [String],
    shortcutsPaused: Bool = false,
    isGrabbed: Bool = false
  ) -> PillState {
    var look: Look {
      if let notice {
        if let answers = notice.answers {
          return .question(notice.message, yes: answers.yes, no: answers.no)
        }
        return .notice(notice.message, canFix: notice.fix != nil, isProblem: notice.isProblem)
      }
      switch phase {
      case .recording(let mode, _, let handsFree):
        // Push to talk records at once but only looks like it a moment later.
        if showsRecording { return isWrappingUp ? .working : .recording(mode: mode, handsFree: handsFree) }
      case .processing:
        return .working
      case .failed(let message):
        return .notice(message, canFix: MacControls.fix(for: message) != nil)
      case .idle:
        break
      }
      // While something is going on the pill is the only feedback, so the "hide" choices stop here.
      guard isEnabled else { return .hidden }
      return isHovered || isGrabbed ? .hint(keys: hintKeys) : .resting
    }
    return PillState(
      look: look,
      meetingSince: meetingSince,
      shortcutsPaused: shortcutsPaused,
      isGrabbed: isGrabbed
    )
  }
}

/// What the pill's buttons do.
struct PillActions {
  var dictate: @MainActor () -> Void = {}
  var stop: @MainActor () -> Void = {}
  var cancel: @MainActor () -> Void = {}
  var tapNotice: @MainActor () -> Void = {}
  /// "No" to a question on the pill.
  var dismissNotice: @MainActor () -> Void = {}
  var stopMeeting: @MainActor () -> Void = {}
  var openMeeting: @MainActor () -> Void = {}
}
