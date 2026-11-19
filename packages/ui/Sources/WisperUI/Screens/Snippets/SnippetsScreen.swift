import SwiftUI
import WisperDomain
import WisperEngine

/// Snippets: say a trigger, get the expansion. Reads `AppModel` from the environment.
public struct SnippetsScreen: View {
  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom

  @State private var query: String
  @State private var editor: SnippetEditor
  @State private var isEditing: Bool
  @State private var deleting: Snippet?
  @State private var isConfirmingDelete: Bool
  @State private var toast: Toast?
  private let hoveredRow: Int?

  /// The list gets a search field from this many snippets up.
  private static let searchFrom = 8
  /// The width of the trigger column on a Mac.
  private static let triggerWidth: CGFloat = 190
  private static let dialogWidth: CGFloat = 560

  public init() {
    self.init(preview: SnippetsPreview())
  }

  /// Starts in a given state, so snapshots can show it.
  init(preview: SnippetsPreview) {
    hoveredRow = preview.hoveredRow
    _query = State(initialValue: preview.query)
    _editor = State(initialValue: preview.editor ?? SnippetEditor())
    _isEditing = State(initialValue: preview.editor != nil)
    _deleting = State(initialValue: preview.deleting)
    _isConfirmingDelete = State(initialValue: preview.deleting != nil)
  }

  public var body: some View {
    Page(
      title: "Snippets",
      subtitle: "Say a short phrase and Open Wisper types the longer text for you."
    ) {
      if idiom == .mac && showsSearch {
        SearchField(text: $query, placeholder: "Search snippets")
      }
      if idiom == .phone {
        IconButton("plus", label: "Add snippet") { open(SnippetEditor()) }
      } else {
        Button("Add snippet") { open(SnippetEditor()) }.buttonStyle(.wisper(.primary))
      }
    } content: {
      if !model.isLoaded {
        ScreenLoading("Loading your snippets…")
      } else if model.snippets.isEmpty {
        empty
      } else {
        list
      }
    }
    .toast($toast)
    .dialog(
      isPresented: $isEditing,
      title: editor.original == nil ? "Add a snippet" : "Edit snippet",
      subtitle: "Say the phrase while you dictate and the text is typed in its place.",
      width: Self.dialogWidth
    ) {
      SnippetEditorFields(editor: $editor, snippets: model.snippets, onSubmit: save)
    } footer: {
      Button("Cancel") { isEditing = false }.buttonStyle(.wisper())
      Button(editor.original == nil ? "Add snippet" : "Save") { save() }
        .buttonStyle(.wisper(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(!editor.check(in: model.snippets).isValid)
    }
    .dialog(
      isPresented: $isConfirmingDelete,
      title: "Delete “\(deleting?.trigger ?? "")”?",
      subtitle: "Saying it will no longer insert the text. This cannot be undone."
    ) {
      if let deleting {
        Card {
          Text(SnippetRules.preview(deleting.expansion)).wisperText(.body).lineLimit(3)
        }
      }
    } footer: {
      // Return must never delete: it presses Cancel.
      Button("Cancel") { isConfirmingDelete = false }.buttonStyle(.wisper()).keyboardShortcut(.defaultAction)
      Button("Delete") { confirmDelete() }.buttonStyle(.wisper(.destructive))
    }
  }

  private var showsSearch: Bool {
    model.snippets.count >= Self.searchFrom || !query.isEmpty
  }

  // MARK: - List

  @ViewBuilder private var list: some View {
    let snippets = SnippetRules.filter(model.snippets, query: query)
    if idiom == .phone && showsSearch {
      SearchField(text: $query, placeholder: "Search snippets")
    }
    if snippets.isEmpty {
      EmptyState(
        "Nothing matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”",
        message: "Search looks in the phrase and in the text it inserts."
      ) {
        SymbolTile("magnifyingglass")
      } action: {
        Button("Clear search") { query = "" }.buttonStyle(.wisper(.tertiary))
      }
    } else {
      PageSection(SnippetRules.count(snippets.count)) {
        CardList(snippets) { snippet in
          row(snippet)
            .rowKeys(open: { open(SnippetEditor(snippet)) }, delete: { askToDelete(snippet) })
            .accessibilityHint("Opens the snippet to edit it.")
            .environment(
              \.simulatedHover,
              hoveredRow.map { snippets.indices.contains($0) && snippets[$0].id == snippet.id } ?? false
            )
        }
      }
    }
  }

  /// On a Mac the phrase and the text sit side by side with an arrow between them.
  /// On iPhone the text goes under the phrase.
  @ViewBuilder private func row(_ snippet: Snippet) -> some View {
    let text = SnippetRules.preview(snippet.expansion)
    if idiom == .phone {
      ListRow("“\(snippet.trigger)”", subtitle: text) {
      } hoverActions: {
        OverflowMenu(label: "Actions for \(snippet.trigger)") {
          Button {
            open(SnippetEditor(snippet))
          } label: {
            Label("Edit", systemImage: "pencil")
          }
          Button(role: .destructive) {
            askToDelete(snippet)
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
      }
      .onTap { open(SnippetEditor(snippet)) }
      .lineLimit(2)
    } else {
      ListRow(text) {
        Text("“\(snippet.trigger)”")
          .wisperText(.bodyStrong)
          .frame(width: Self.triggerWidth, alignment: .leading)
        Image(systemName: "arrow.right")
          .wisperText(.caption, color: Wisper.Color.textTertiary)
          .accessibilityHidden(true)
      } hoverActions: {
        IconButton("pencil", label: "Edit \(snippet.trigger)") { open(SnippetEditor(snippet)) }
        IconButton("trash", label: "Delete \(snippet.trigger)") { askToDelete(snippet) }
      }
      .onTap { open(SnippetEditor(snippet)) }
      .lineLimit(2)
    }
  }

  // MARK: - Empty

  private var empty: some View {
    EmptyState(
      "No snippets yet",
      message: "Save text you type again and again, such as a link, a sign-off or your address."
    ) {
      SymbolTile("text.quote")
    } action: {
      VStack(spacing: Wisper.Space.m) {
        Text("Start from an example").wisperText(.sectionLabel)
        ChipRow(SnippetSample.all(userName: model.settings.userName)) { sample in
          Button {
            open(SnippetEditor(trigger: sample.trigger, expansion: sample.expansion))
          } label: {
            Label(sample.title, systemImage: "plus")
          }
          .buttonStyle(.wisper(.tertiary, size: .small))
          .accessibilityLabel("Start from the example: \(sample.title)")
        }
      }
    }
  }

  // MARK: - Actions

  private func open(_ editor: SnippetEditor) {
    self.editor = editor
    isEditing = true
  }

  private func askToDelete(_ snippet: Snippet) {
    deleting = snippet
    isConfirmingDelete = true
  }

  private func save() {
    // Return in a field can reach this twice: from the field and from the default button.
    guard isEditing else { return }
    guard editor.check(in: model.snippets).isValid else {
      editor.showsProblems = true
      return
    }
    let snippet = editor.snippet
    let isNew = editor.original == nil
    isEditing = false
    model.run { try await $0.library.save(snippet) }
    toast = Toast(isNew ? "Added “\(snippet.trigger)”" : "Saved")
  }

  private func confirmDelete() {
    isConfirmingDelete = false
    guard let id = deleting?.id else { return }
    model.run { try await $0.library.deleteSnippet(id) }
  }
}

/// What is being typed in the add or edit dialog.
struct SnippetEditor: Equatable {
  var trigger = ""
  var expansion = ""
  /// The snippet being edited, or `nil` when adding.
  var original: Snippet?
  /// Set once the person tried to save, so an empty field says what is missing.
  var showsProblems = false

  init() {}

  init(_ snippet: Snippet) {
    trigger = snippet.trigger
    expansion = snippet.expansion
    original = snippet
  }

  init(trigger: String, expansion: String, showsProblems: Bool = false) {
    self.trigger = trigger
    self.expansion = expansion
    self.showsProblems = showsProblems
  }

  func check(in snippets: [Snippet]) -> SnippetRules.Check {
    SnippetRules.check(trigger: trigger, expansion: expansion, editing: original?.id, in: snippets)
  }

  var snippet: Snippet {
    SnippetRules.snippet(trigger: trigger, expansion: expansion, replacing: original)
  }
}

/// The two fields of the add or edit dialog.
private struct SnippetEditorFields: View {
  @Binding var editor: SnippetEditor
  let snippets: [Snippet]
  let onSubmit: () -> Void

  private static let editorHeight: CGFloat = 132

  var body: some View {
    let check = editor.check(in: snippets)
    // An empty field is only called out after a try to save; other problems are said right away.
    let triggerProblem = check.trigger == .emptyTrigger && !editor.showsProblems ? nil : check.trigger
    WisperTextField(
      "When I say",
      text: $editor.trigger,
      placeholder: "For example, my calendar link",
      error: triggerProblem?.message,
      focusOnAppear: true
    )
    .onSubmit(onSubmit)
    WisperTextEditor(
      "Insert",
      text: $editor.expansion,
      placeholder: "The text to type for you",
      error: editor.showsProblems ? check.expansion?.message : nil,
      height: Self.editorHeight
    )
  }
}

/// A starting state for `SnippetsScreen`, so snapshots can show its dialogs.
struct SnippetsPreview {
  var query = ""
  /// The row drawn as if the pointer were over it, counted from the top.
  var hoveredRow: Int?
  /// The add or edit dialog, open with this content.
  var editor: SnippetEditor?
  /// The snippet whose delete question is open.
  var deleting: Snippet?
}
