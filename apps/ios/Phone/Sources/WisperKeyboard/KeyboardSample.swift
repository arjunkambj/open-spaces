import Foundation
import WisperDomain

extension KeyboardModel {
  /// A keyboard filled with made-up text whose keys do nothing: for showing what the
  /// keyboard looks like, in the app's setup guide and in snapshots.
  @MainActor
  public static var sample: KeyboardModel {
    sample(
      snippets: SampleData.snippets(),
      latest: "Sounds good, I'll take a look after lunch and leave comments."
    )
  }

  /// A keyboard in a given state whose keys do nothing.
  @MainActor
  public static func sample(
    snippets: [Snippet] = [],
    latest: String? = nil,
    problem: Problem? = nil
  ) -> KeyboardModel {
    let model = KeyboardModel(
      library: nil,
      host: KeyboardHost(
        insert: { _ in },
        deleteBackward: {},
        nextKeyboard: {},
        open: { _ in true },
        hasFullAccess: { true }
      )
    )
    model.show(snippets: snippets, latest: latest, problem: problem)
    return model
  }
}
