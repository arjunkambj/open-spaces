import SpacesDomain
import SpacesEngine
import SwiftUI
import UniformTypeIdentifiers

/// One meeting: its title, tags and status, then its notes, transcript and the user's own notes.
/// Also the page of the meeting being recorded, which shows the transcript as it grows.
struct MeetingDetail: View {
  let id: Meeting.ID
  /// Whether the page draws its own back button. False where the system's bar has one.
  let showsBack: Bool
  let questions: MeetingQuestions
  private let preset: MeetingsPreset
  /// Goes back to the list.
  private let onClose: () -> Void

  @Environment(AppModel.self) private var model
  @Environment(\.spacesIdiom) private var idiom

  @State private var tab: MeetingTab
  @State private var find: String
  /// The text the matches are shown for: `find`, a moment after the typing stops.
  @State private var sought: String
  @State private var findIndex = 0
  @State private var index = MeetingTranscriptIndex()
  @State private var deleting: Meeting?
  @State private var deletingItem: ActionItem?
  @State private var isConfirmingRewrite = false
  @State private var isRenaming = false
  @State private var newTitle = ""
  /// The speaker whose new name is being typed.
  @State private var renamingSpeaker: Speaker?
  @State private var newSpeakerName = ""
  @State private var isExporting = false
  @State private var isStopping = false
  @State private var toast: Toast?
  /// Set once the meeting has been seen, so a meeting that then goes away was deleted.
  @State private var wasFound = false

  init(
    id: Meeting.ID,
    showsBack: Bool,
    questions: MeetingQuestions,
    preset: MeetingsPreset = MeetingsPreset(),
    onClose: @escaping () -> Void
  ) {
    self.id = id
    self.showsBack = showsBack
    self.questions = questions
    self.preset = preset
    self.onClose = onClose
    _tab = State(initialValue: preset.tab)
    _find = State(initialValue: preset.find)
    _sought = State(initialValue: preset.find)
  }

  var body: some View {
    let meeting = current
    ScrollViewReader { proxy in
      Group {
        if let meeting {
          found(meeting, proxy: proxy)
        } else if model.isLoaded {
          framed(
            Page(title: "Meeting") {
              EmptyState("This meeting is not here", message: "It may have been deleted.") {
                SymbolTile("questionmark.folder")
              } action: {
                Button("Back to meetings", action: onClose)
                  .buttonStyle(.spaces(.tertiary))
              }
            }
          )
        } else {
          framed(Page(title: "Meeting") { MeetingsLoading() })
        }
      }
    }
    .onChange(of: meeting != nil, initial: true) { _, isThere in
      if isThere {
        wasFound = true
      } else if wasFound {
        // Deleted here, by an agent or on another screen.
        onClose()
      }
    }
    .dialog(isPresented: isRenamingSpeaker, title: speakerDialogTitle, subtitle: speakerDialogSubtitle) {
      SpacesTextField(text: $newSpeakerName, placeholder: "Name", focusOnAppear: true)
        .onSubmit(renameSpeaker)
    } footer: {
      Button("Cancel") { renamingSpeaker = nil }
        .buttonStyle(.spaces())
      Button("Save", action: renameSpeaker)
        .buttonStyle(.spaces(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(Meeting.speakerName(newSpeakerName) == nil)
    }
  }

  // MARK: The meeting

  /// The stored meeting, with the newest transcript while it is being recorded. Right after
  /// a recording starts the list may not hold the meeting yet; the engine's copy stands in.
  private var current: Meeting? {
    let live = model.meetings.live.flatMap { $0.meetingID == id ? $0 : nil }
    if var stored = model.meetingList.first(where: { $0.id == id }) {
      if let live { stored.segments = live.segments }
      return stored
    }
    guard let live else { return nil }
    return Meeting(
      id: id,
      title: live.title,
      startedAt: live.startedAt,
      status: .recording,
      segments: live.segments
    )
  }

  private func found(_ meeting: Meeting, proxy: ScrollViewProxy) -> some View {
    let phone = idiom == .phone
    let phase = MeetingsLogic.phase(
      of: meeting,
      liveID: model.meetings.live?.meetingID,
      processing: model.meetings.processing
    )
    let turns = index.turns(of: meeting.segments)
    let matches = tab == .transcript ? index.matches(of: sought, in: meeting.segments) : []
    let matchIndex = min(findIndex, max(matches.count - 1, 0))
    let thread = questions.thread(for: id)
    let canAsk = phase != .live && phase != .processing && hasSomethingToAskAbout(meeting)
    // While the transcript is being written, the engine would write over a new name.
    let canRename = phase != .live && phase != .processing
    let onRenameSpeaker: ((Speaker) -> Void)? = canRename ? { startRenaming($0) } : nil

    return VStack(spacing: 0) {
      framed(
        Page(title: phone ? meeting.title : "") {
          toolbar(meeting, phase: phase)
        } content: {
          header(meeting, phase: phase)
          if let problem = MeetingsLogic.problem(of: meeting, phase: phase) {
            Banner(problem.isSevere ? .error : .warning, title: problem.title, message: problem.message) {
              if let remedy = problem.remedy {
                Button(problem.actionTitle) { MeetingActions.fix(remedy, id, in: model) }
                  .buttonStyle(.spaces(.tertiary, size: .small))
              }
            }
          }
          Tabs(selection: $tab, options: MeetingTab.allCases, style: phone ? .segmented : .underline) {
            $0.title
          }
          switch tab {
          case .notes:
            MeetingNotesTab(
              meeting: meeting,
              phase: phase,
              thread: thread,
              edit: edit,
              onDeleteItem: { deletingItem = $0 },
              onAskAgain: { entry in
                Task { await questions.askAgain(entry, about: id, with: model.meetings) }
              }
            )
          case .transcript:
            MeetingTranscriptTab(
              turns: turns,
              phase: phase,
              matches: matches,
              currentMatch: matches.isEmpty ? nil : matches[matchIndex],
              onRename: onRenameSpeaker
            )
          case .myNotes:
            MeetingMyNotesTab(meeting: meeting)
          }
        }
      )
      if tab == .notes, canAsk {
        MeetingAskBar(showsSuggestions: thread.isEmpty, isWaiting: questions.isWaiting(for: id)) { question in
          Task { await questions.ask(question, about: id, with: model.meetings) }
        }
      } else if tab == .transcript, !turns.isEmpty {
        let isSearching = !sought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        MeetingFindBar(text: $find, isSearching: isSearching, count: matches.count, index: matchIndex) {
          offset in
          findIndex = MeetingsLogic.step(matchIndex, by: offset, count: matches.count)
        } onCopy: {
          copyTranscript(meeting)
        }
      }
    }
    .toast($toast)
    .meetingDeleteDialog($deleting) { doomed in
      MeetingActions.delete(doomed.id, in: model)
      onClose()
    }
    .meetingConfirmDialog(
      isPresented: Binding(get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } }),
      title: "Delete this action item?",
      message: "“\(deletingItem?.text ?? "")” is removed from this meeting's notes.",
      confirm: "Delete"
    ) {
      if let item = deletingItem?.id {
        edit { $0.notes?.actionItems.removeAll { $0.id == item } }
      }
    }
    .meetingConfirmDialog(
      isPresented: $isConfirmingRewrite,
      title: "Write the notes again?",
      message: "The summary, key points, decisions and action items are written again from the "
        + "transcript and replace the ones here. Your own notes stay as they are.",
      confirm: "Write again",
      isDestructive: false
    ) {
      MeetingActions.writeNotes(id, in: model)
    }
    .dialog(isPresented: $isRenaming, title: "Rename this meeting") {
      SpacesTextField(text: $newTitle, placeholder: "Meeting title", focusOnAppear: true)
        .onSubmit(rename)
    } footer: {
      Button("Cancel") { isRenaming = false }
        .buttonStyle(.spaces())
      Button("Save", action: rename)
        .buttonStyle(.spaces(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .fileExporter(
      isPresented: $isExporting,
      // Written only while the save panel is open.
      document: MeetingMarkdownFile(text: isExporting ? meeting.markdown() : ""),
      contentType: MeetingMarkdownFile.type,
      defaultFilename: MeetingsLogic.fileName(for: meeting)
    ) { result in
      if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
    }
    .task(id: find) {
      // The first letter is looked for at once; after that, a pause in the typing is waited for.
      if !sought.isEmpty, !find.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
      if !Task.isCancelled { sought = find }
    }
    .onChange(of: sought) { findIndex = 0 }
    .onChange(of: matches.isEmpty ? nil : matches[matchIndex]) { _, match in
      guard let match else { return }
      withAnimation(Spaces.Motion.smooth) { proxy.scrollTo(match.turn, anchor: .center) }
    }
    .onChange(of: meeting.segments.count) {
      // While recording, keep the newest words in view unless the user is looking for something.
      guard phase == .live, tab == .transcript, matches.isEmpty, let last = turns.last else { return }
      withAnimation(Spaces.Motion.smooth) { proxy.scrollTo(last.id, anchor: .bottom) }
    }
    .onChange(of: thread) { _, thread in
      guard let last = thread.last else { return }
      withAnimation(Spaces.Motion.smooth) { proxy.scrollTo(last.id, anchor: .bottom) }
    }
    .onAppear {
      if preset.confirmsDelete { deleting = meeting }
      if let speaker = preset.renamesSpeaker { startRenaming(speaker) }
    }
  }

  /// Gives a page its back button, where this screen is the one that draws it.
  private func framed<Toolbar: View, Content: View>(_ page: Page<Toolbar, Content>) -> Page<Toolbar, Content>
  {
    showsBack ? page.onBack(onClose) : page
  }

  private func hasSomethingToAskAbout(_ meeting: Meeting) -> Bool {
    !meeting.segments.isEmpty || meeting.notes != nil || !meeting.userNotes.isEmpty
  }

  /// Changes the stored meeting, never a copy this screen holds: the engine or an agent
  /// may be writing to the same meeting.
  private func edit(_ change: @escaping @Sendable (inout Meeting) -> Void) {
    let id = id
    model.run { _ = try await $0.library.updateMeeting(id, change) }
  }

  private func rename() {
    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    // Return in the field can reach this twice: from the field and from the default button.
    guard isRenaming, !title.isEmpty else { return }
    isRenaming = false
    edit { $0.title = title }
  }

  private var isRenamingSpeaker: Binding<Bool> {
    Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })
  }

  private var speakerDialogTitle: String { "Rename “\(renamingSpeaker?.label ?? "")”" }

  private let speakerDialogSubtitle =
    "Every line they said in this meeting, and every task they own, gets the new name."

  private func startRenaming(_ speaker: Speaker) {
    // A voice that has no name yet starts empty; a name starts as it is, to be corrected.
    newSpeakerName = speaker == .others || speaker.unnamedNumber != nil ? "" : speaker.label
    renamingSpeaker = speaker
  }

  private func renameSpeaker() {
    // Return in the field can reach this twice: from the field and from the default button.
    guard let speaker = renamingSpeaker, let name = Meeting.speakerName(newSpeakerName) else { return }
    renamingSpeaker = nil
    edit { $0.renameSpeaker(speaker, to: name) }
  }

  // MARK: Header

  @ViewBuilder
  private func toolbar(_ meeting: Meeting, phase: MeetingPhase) -> some View {
    let phone = idiom == .phone
    if phase == .live {
      if !phone { MeetingRecordingStamp(startedAt: meeting.startedAt) }
      Button {
        isStopping = true
        Task { await model.meetings.stop() }
      } label: {
        Label("Stop", systemImage: "stop.fill")
      }
      .buttonStyle(.spaces(.primary, size: phone ? .small : .regular))
      .disabled(isStopping)
      .accessibilityLabel("Stop recording")
    } else if !phone {
      IconButton("doc.on.doc", label: "Copy the notes and transcript") { copyMarkdown(meeting) }
      ShareLink(item: MeetingShare(meeting: meeting), preview: SharePreview(meeting.title)) {
        Image(systemName: "square.and.arrow.up")
      }
      .buttonStyle(IconButtonStyle())
      .help("Share")
      .accessibilityLabel("Share")
    }
    OverflowMenu {
      if phone {
        Button("Rename") {
          newTitle = meeting.title
          isRenaming = true
        }
        if phase != .live {
          Button("Copy notes and transcript") { copyMarkdown(meeting) }
          Button("Copy transcript only") { copyTranscript(meeting) }
          ShareLink("Share", item: MeetingShare(meeting: meeting), preview: SharePreview(meeting.title))
        }
      } else if phase != .live {
        Button("Save as a file…") { isExporting = true }
      }
      if phase != .live {
        Button(meeting.notes == nil ? "Write notes" : "Write notes again") {
          // Nothing is lost when there are no notes yet, so there is nothing to ask.
          if meeting.notes == nil {
            MeetingActions.writeNotes(id, in: model)
          } else {
            isConfirmingRewrite = true
          }
        }
        .disabled(phase == .processing || meeting.segments.isEmpty)
        Divider()
      }
      Button("Delete meeting", role: .destructive) { deleting = meeting }
    }
  }

  private func header(_ meeting: Meeting, phase: MeetingPhase) -> some View {
    VStack(alignment: .leading, spacing: Spaces.Space.s) {
      if idiom == .mac {
        MeetingInlineText(text: meeting.title, style: .pageTitle, label: "Meeting title") { title in
          edit { $0.title = title }
        }
      }
      if idiom == .phone, phase == .live {
        MeetingRecordingStamp(startedAt: meeting.startedAt)
      }
      Text(facts(meeting, phase: phase))
        .spacesText(.body, color: Spaces.Color.textSecondary)
      if !meeting.attendees.isEmpty {
        Text("With \(meeting.attendees.formatted(.list(type: .and)))")
          .spacesText(.caption, color: Spaces.Color.textSecondary)
          .lineLimit(2)
          .accessibilityLabel("Invited: \(meeting.attendees.formatted(.list(type: .and)))")
      }
      MeetingTagEditor(tags: meeting.tags, startsEditing: preset.editsTags) { typed in
        edit { $0.tags = MeetingsLogic.adding(typed, to: $0.tags) }
      } onRemove: { tag in
        edit { $0.tags.removeAll { $0 == tag } }
      } leading: {
        if phase == .processing { Badge("Writing notes…", tone: .accent) }
      }
    }
  }

  private func facts(_ meeting: Meeting, phase: MeetingPhase) -> String {
    // The short forms keep it on one line on a phone.
    let day =
      idiom == .phone
      ? meeting.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
      : meeting.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    let time = meeting.startedAt.formatted(date: .omitted, time: .shortened)
    let length = phase == .live ? nil : MeetingsLogic.length(meeting.duration)
    return [day, time, length].compactMap { $0 }.joined(separator: " · ")
  }

  // MARK: Actions

  private func copyMarkdown(_ meeting: Meeting) {
    MeetingActions.copy(meeting.markdown())
    toast = Toast("Copied")
  }

  private func copyTranscript(_ meeting: Meeting) {
    MeetingActions.copy(meeting.transcriptText)
    toast = Toast("Transcript copied")
  }
}

// MARK: - Tags

/// The tags of a meeting as chips that can be removed, and a way to add more.
private struct MeetingTagEditor<Leading: View>: View {
  let tags: [String]
  let startsEditing: Bool
  let onAdd: (String) -> Void
  let onRemove: (String) -> Void
  @ViewBuilder let leading: Leading

  @State private var isAdding = false
  @State private var draft = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    MeetingFlow(lineSpacing: Spaces.Space.s) {
      leading
      ForEach(tags, id: \.self) { tag in
        Button {
          onRemove(tag)
        } label: {
          HStack(spacing: Spaces.Space.xs) {
            Text(tag)
            Image(systemName: "xmark")
              .imageScale(.small)
              .foregroundStyle(Spaces.Color.textTertiary)
          }
          .spacesText(.captionStrong, color: Spaces.Color.textSecondary)
          .modifier(MeetingChip(fill: Spaces.Color.surfaceSelected))
        }
        .buttonStyle(.plain)
        .help("Remove this tag")
        .accessibilityLabel("Remove tag \(tag)")
      }
      if isAdding {
        TextField("", text: $draft, prompt: Text("Tag name").foregroundStyle(Spaces.Color.textTertiary))
          .textFieldStyle(.plain)
          .spacesText(.caption, color: Spaces.Color.textPrimary)
          .focused($isFocused)
          .focusEffectDisabled()
          .frame(width: MeetingsMetrics.tagField)
          .modifier(MeetingChip(fill: Spaces.Color.raised, border: Spaces.Color.borderStrong))
          .onSubmit {
            if !MeetingsLogic.tags(from: draft).isEmpty { onAdd(draft) }
            draft = ""
          }
          .onChange(of: isFocused) { _, focused in
            if !focused, !startsEditing { close() }
          }
          .onAppear { isFocused = true }
          #if os(macOS)
            .onExitCommand(perform: close)
          #endif
          .accessibilityLabel("New tag")
      } else {
        Button {
          isAdding = true
        } label: {
          Label("Add tag", systemImage: "plus")
            .labelStyle(MeetingChipLabel())
            .spacesText(.caption, color: Spaces.Color.textTertiary)
            .modifier(MeetingChip(fill: .clear))
        }
        .buttonStyle(.plain)
      }
    }
    .onAppear { isAdding = startsEditing }
  }

  private func close() {
    if !MeetingsLogic.tags(from: draft).isEmpty { onAdd(draft) }
    draft = ""
    isAdding = false
  }
}

/// The small rounded box of a tag.
private struct MeetingChip: ViewModifier {
  let fill: SwiftUI.Color
  var border: SwiftUI.Color = .clear
  @Environment(\.spacesIdiom) private var idiom

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.small, style: .continuous)
    content
      .lineLimit(1)
      .padding(.horizontal, Spaces.Space.s)
      .frame(minHeight: MeetingsMetrics.tagHeight(idiom))
      .background(fill, in: shape)
      .overlay { shape.strokeBorder(border, lineWidth: Spaces.Stroke.hairline) }
      .contentShape(shape)
  }
}

private struct MeetingChipLabel: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Spaces.Space.xs) {
      configuration.icon.imageScale(.small)
      configuration.title
    }
  }
}

// MARK: - Export

/// The meeting as a Markdown file, for "Save as…".
private struct MeetingMarkdownFile: FileDocument {
  static let type = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
  static let readableContentTypes = [type, UTType.plainText]

  var text: String

  init(text: String) {
    self.text = text
  }

  init(configuration: ReadConfiguration) throws {
    text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}
