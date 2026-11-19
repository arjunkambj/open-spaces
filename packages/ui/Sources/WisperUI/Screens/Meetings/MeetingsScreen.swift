import SwiftUI
import WisperDomain
import WisperEngine

/// Meetings: the list, the live recording and one meeting's notes and transcript.
/// `selection` is the open meeting (`nil` shows the list); the shell sets it for deep links.
/// Reads `AppModel` from the environment.
///
/// On a Mac the open meeting takes the place of the list, with a back button. On iPhone it is
/// pushed onto the `NavigationStack` the app provides.
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
    #if os(iOS)
      MeetingsList(selection: $selection, isShown: selection == nil, preset: preset)
        .navigationDestination(item: $selection) { id in
          // The system's bar brings the back button and the swipe back.
          detail(id, showsBack: false)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
        }
    #else
      // The list stays alive under the open meeting, so it is where it was left on the way back.
      ZStack {
        MeetingsList(selection: $selection, isShown: selection == nil, preset: preset)
          .opacity(selection == nil ? 1 : 0)
          .disabled(selection != nil)
          .accessibilityHidden(selection != nil)
        if let id = selection {
          detail(id, showsBack: true).id(id)
        }
      }
    #endif
  }

  private func detail(_ id: Meeting.ID, showsBack: Bool) -> some View {
    MeetingDetail(id: id, showsBack: showsBack, questions: questions, preset: preset) {
      selection = nil
    }
  }
}
