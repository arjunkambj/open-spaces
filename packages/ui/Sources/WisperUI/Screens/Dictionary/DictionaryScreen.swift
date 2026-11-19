import SwiftUI
import WisperDomain
import WisperEngine

/// The personal dictionary: words and replacements. Reads `AppModel` from the environment.
public struct DictionaryScreen: View {
  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom

  @State private var query: String
  @State private var editor: DictionaryEditor
  @State private var isEditing: Bool
  @State private var deleting: DictionaryWord?
  @State private var isConfirmingDelete: Bool
  @State private var toast: Toast?
  private let hoveredRow: Int?

  /// The list gets a search field from this many words up.
  private static let searchFrom = 8

  public init() {
    self.init(preview: DictionaryPreview())
  }

  /// Starts in a given state, so snapshots can show it.
  init(preview: DictionaryPreview) {
    hoveredRow = preview.hoveredRow
    _query = State(initialValue: preview.query)
    _editor = State(initialValue: preview.editor ?? DictionaryEditor())
    _isEditing = State(initialValue: preview.editor != nil)
    _deleting = State(initialValue: preview.deleting)
    _isConfirmingDelete = State(initialValue: preview.deleting != nil)
  }

  public var body: some View {
    Page(
      title: "Dictionary",
      subtitle: "Teach Open Wisper your names and special words, so it spells them your way."
    ) {
      if idiom == .mac && showsSearch {
        SearchField(text: $query, placeholder: "Search words")
      }
      if idiom == .phone {
        IconButton("plus", label: "Add word") { open(DictionaryEditor()) }
      } else {
        Button("Add word") { open(DictionaryEditor()) }.buttonStyle(.wisper(.primary))
      }
    } content: {
      if !model.isLoaded {
        ScreenLoading("Loading your words…")
      } else if model.words.isEmpty {
        empty
      } else {
        list
      }
    }
    .toast($toast)
    .dialog(
      isPresented: $isEditing,
      title: editor.original == nil ? "Add a word" : "Edit word",
      subtitle: "Open Wisper will spell it this way from now on."
    ) {
      DictionaryEditorFields(editor: $editor, words: model.words, onSubmit: save)
    } footer: {
      Button("Cancel") { isEditing = false }.buttonStyle(.wisper())
      Button(editor.original == nil ? "Add word" : "Save") { save() }
        .buttonStyle(.wisper(.primary))
        .disabled(!editor.check(in: model.words).isValid)
    }
    .dialog(
      isPresented: $isConfirmingDelete,
      title: "Delete “\(deleting?.text ?? "")”?",
      subtitle: deleting?.replaces == nil
        ? "Open Wisper will stop spelling it this way."
        : "Open Wisper will stop spelling it this way and stop replacing “\(deleting?.replaces ?? "")”."
    ) {
    } footer: {
      Button("Cancel") { isConfirmingDelete = false }.buttonStyle(.wisper())
      Button("Delete") { confirmDelete() }.buttonStyle(.wisper(.destructive))
    }
  }

  private var showsSearch: Bool {
    model.words.count >= Self.searchFrom || !query.isEmpty
  }

  // MARK: - List

  @ViewBuilder private var list: some View {
    let words = DictionaryRules.filter(model.words, query: query)
    if idiom == .phone && showsSearch {
      SearchField(text: $query, placeholder: "Search words")
    }
    if words.isEmpty {
      EmptyState(
        "Nothing matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”",
        message: "Check the spelling, or add it as a new word."
      ) {
        SymbolTile("magnifyingglass")
      } action: {
        Button("Clear search") { query = "" }.buttonStyle(.wisper(.tertiary))
      }
    } else {
      PageSection(DictionaryRules.count(words.count)) {
        CardList(words) { word in
          ListRow(word.text, subtitle: word.replaces.map { "Replaces “\($0)”" }) {
          } hoverActions: {
            if idiom == .phone {
              OverflowMenu(label: "Actions for \(word.text)") {
                Button {
                  open(DictionaryEditor(word))
                } label: {
                  Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                  askToDelete(word)
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
            } else {
              IconButton("pencil", label: "Edit \(word.text)") { open(DictionaryEditor(word)) }
              IconButton("trash", label: "Delete \(word.text)") { askToDelete(word) }
            }
          }
          .onTap { open(DictionaryEditor(word)) }
          .lineLimit(2)
          .rowKeys(open: { open(DictionaryEditor(word)) }, delete: { askToDelete(word) })
          .accessibilityHint("Opens the word to edit it.")
          .environment(
            \.simulatedHover,
            hoveredRow.map { words.indices.contains($0) && words[$0].id == word.id } ?? false
          )
        }
      }
    }
  }

  // MARK: - Empty

  private var empty: some View {
    EmptyState(
      "No words yet",
      message:
        "Add names, places and terms that are easy to mishear. They are spelled your way in every dictation."
    ) {
      SymbolTile("character.book.closed")
    } action: {
      VStack(spacing: Wisper.Space.m) {
        Text("Try one").wisperText(.sectionLabel)
        ChipRow(DictionarySamples.words(userName: model.settings.userName)) { sample in
          Button {
            add(sample)
          } label: {
            Label(sample.text, systemImage: "plus")
          }
          .buttonStyle(.wisper(.tertiary, size: .small))
          .accessibilityLabel("Add \(sample.text)")
        }
      }
    }
  }

  // MARK: - Actions

  private func open(_ editor: DictionaryEditor) {
    self.editor = editor
    isEditing = true
  }

  private func askToDelete(_ word: DictionaryWord) {
    deleting = word
    isConfirmingDelete = true
  }

  private func save() {
    guard editor.check(in: model.words).isValid else {
      editor.showsProblems = true
      return
    }
    let word = editor.word
    let isNew = editor.original == nil
    isEditing = false
    model.run { try await $0.library.save(word) }
    toast = Toast(isNew ? "Added “\(word.text)”" : "Saved")
  }

  private func add(_ sample: DictionaryWord) {
    let word = DictionaryRules.word(text: sample.text, heardAs: sample.replaces ?? "")
    model.run { try await $0.library.save(word) }
    toast = Toast("Added “\(word.text)”")
  }

  private func confirmDelete() {
    isConfirmingDelete = false
    guard let id = deleting?.id else { return }
    model.run { try await $0.library.deleteWord(id) }
  }
}

/// What is being typed in the add or edit dialog.
struct DictionaryEditor: Equatable {
  var text = ""
  var heardAs = ""
  /// The word being edited, or `nil` when adding.
  var original: DictionaryWord?
  /// Set once the person tried to save, so an empty field says what is missing.
  var showsProblems = false

  init() {}

  init(_ word: DictionaryWord) {
    text = word.text
    heardAs = word.replaces ?? ""
    original = word
  }

  init(text: String, heardAs: String = "", showsProblems: Bool = false) {
    self.text = text
    self.heardAs = heardAs
    self.showsProblems = showsProblems
  }

  func check(in words: [DictionaryWord]) -> DictionaryRules.Check {
    DictionaryRules.check(text: text, heardAs: heardAs, editing: original?.id, in: words)
  }

  var word: DictionaryWord {
    DictionaryRules.word(text: text, heardAs: heardAs, replacing: original)
  }
}

/// The two fields of the add or edit dialog.
private struct DictionaryEditorFields: View {
  @Binding var editor: DictionaryEditor
  let words: [DictionaryWord]
  let onSubmit: () -> Void

  var body: some View {
    let check = editor.check(in: words)
    // An empty field is only called out after a try to save; a clash is said right away.
    let wordProblem = check.word == .empty && !editor.showsProblems ? nil : check.word
    WisperTextField(
      "Word or name",
      text: $editor.text,
      placeholder: "For example, Kubernetes",
      error: wordProblem?.message
    )
    .onSubmit(onSubmit)
    VStack(alignment: .leading, spacing: Wisper.Space.s) {
      WisperTextField(
        "It is often heard as (optional)",
        text: $editor.heardAs,
        placeholder: "For example, cooper netties",
        error: check.heardAs?.message
      )
      .onSubmit(onSubmit)
      Text("When Open Wisper hears this, it writes your word instead.")
        .wisperText(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A starting state for `DictionaryScreen`, so snapshots can show its dialogs.
struct DictionaryPreview {
  var query = ""
  /// The row drawn as if the pointer were over it, counted from the top.
  var hoveredRow: Int?
  /// The add or edit dialog, open with this content.
  var editor: DictionaryEditor?
  /// The word whose delete question is open.
  var deleting: DictionaryWord?
}

/// Example words for an empty dictionary.
enum DictionarySamples {
  /// The person's own name first, when it is known: it is the word most worth teaching.
  static func words(userName: String) -> [DictionaryWord] {
    let name = SpokenPhrase.tidy(userName)
    let own = name.isEmpty ? [] : [DictionaryWord(text: name)]
    return own + [
      DictionaryWord(text: "Kubernetes", replaces: "cooper netties"),
      DictionaryWord(text: "PostgreSQL", replaces: "post gres"),
    ]
  }
}
