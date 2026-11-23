import SpacesDomain
import SpacesEngine
import SwiftUI

/// Meetings: the list, the live recording and one meeting's notes and transcript.
/// `selection` is the open meeting (`nil` shows the list); the shell sets it for deep links.
/// Reads `AppModel` from the environment.
///
/// The open meeting takes the place of the list, with a back button.
public struct MeetingsScreen: View {
  @Binding private var selection: Meeting.ID?
  private let preset: MeetingsPreset
  /// The threads of this run of the app, kept outside the screen: they are still there after
  /// going back to the list, and after another section of the hub was shown.
  @State private var questions: MeetingQuestions

  public init(selection: Binding<Meeting.ID?>) {
    self.init(selection: selection, preset: MeetingsPreset())
  }

  /// For snapshots: starts with a tab, a dialog or typed text already in place.
  init(selection: Binding<Meeting.ID?>, preset: MeetingsPreset) {
    _selection = selection
    self.preset = preset
    _questions = State(initialValue: preset.questions ?? .session)
  }

  public var body: some View {
    // The list stays alive under the open meeting, so it is where it was left on the way back.
    ZStack {
      MeetingsList(selection: $selection, isShown: selection == nil, preset: preset)
        .opacity(selection == nil ? 1 : 0)
        .disabled(selection != nil)
        .accessibilityHidden(selection != nil)
      if let id = selection {
        detail(id).id(id)
      }
    }
  }

  private func detail(_ id: Meeting.ID) -> some View {
    MeetingDetail(id: id, questions: questions, preset: preset) {
      selection = nil
    }
  }
}
