import SwiftUI
import WisperDomain
import WisperEngine

/// Meetings: the list, the live recording and one meeting's notes and transcript.
/// `selection` is the open meeting (`nil` shows the list); the shell sets it for deep links.
/// Reads `AppModel` from the environment.
public struct MeetingsScreen: View {
  @Binding private var selection: Meeting.ID?

  public init(selection: Binding<Meeting.ID?>) {
    _selection = selection
  }

  public var body: some View {
    // CONTRACT STUB: the screen builder replaces this body.
    Text("MeetingsScreen")
  }
}
