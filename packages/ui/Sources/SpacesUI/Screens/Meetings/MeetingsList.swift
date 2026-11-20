import SpacesDomain
import SpacesEngine
import SwiftUI

/// The list of meetings: start a recording, watch the live one, find and open past ones.
struct MeetingsList: View {
  @Binding var selection: Meeting.ID?
  /// False while an open meeting covers the list. The live waveform rests then.
  private let isShown: Bool
  private let preset: MeetingsPreset

  @Environment(AppModel.self) private var model
  @Environment(\.spacesIdiom) private var idiom

  @State private var query: String
  /// The meetings the search found. `nil` while nothing is being searched for.
  @State private var found: Set<Meeting.ID>?
  /// Goes up when the stored meetings change under a search, so the search runs again.
  @State private var searchRound = 0
  @State private var deleting: Meeting?
  @State private var toast: Toast?
  @State private var isStarting = false
  /// The permission the last failed start was missing, when that was the reason.
  @State private var deniedPermission: Permission?

  init(selection: Binding<Meeting.ID?>, isShown: Bool = true, preset: MeetingsPreset = MeetingsPreset()) {
    _selection = selection
    self.isShown = isShown
    self.preset = preset
    _query = State(initialValue: preset.query)
  }

  var body: some View {
    let live = model.meetings.live
    let past = pastMeetings(liveID: live?.meetingID)
    let searching = MeetingSearchTrigger(query: query, round: searchRound)
    Page(title: "Meetings") {
      if idiom == .mac, hasPastMeetings(liveID: live?.meetingID) {
        SearchField(text: $query, placeholder: "Search meetings")
      }
      if live == nil { startButton(.primary) }
    } content: {
      if hasNotices { VStack(spacing: Spaces.Space.m) { notices(isLive: live != nil) } }
      if let live {
        // The stored title, so a rename made while recording shows here too.
        let title = model.meetingList.first { $0.id == live.meetingID }?.title ?? live.title
        MeetingLiveCard(title: title, live: live, showsLevel: isShown) {
          selection = live.meetingID
        } onStop: {
          Task { await model.meetings.stop() }
        }
      }
      if idiom == .phone, hasPastMeetings(liveID: live?.meetingID) {
        SearchField(text: $query, placeholder: "Search meetings")
      }
      if !model.isLoaded {
        MeetingsLoading()
      } else if past.isEmpty {
        emptyState(isLive: live != nil)
      } else {
        ForEach(MeetingsLogic.groups(past)) { group in
          PageSection(group.title) {
            CardList(group.meetings) { meeting in row(meeting) }
          }
        }
      }
    }
    .toast($toast)
    .meetingDeleteDialog($deleting) { meeting in
      MeetingActions.delete(meeting.id, in: model)
    }
    .task(id: searching) { await search(for: searching.text) }
    .onChange(of: model.meetingList) {
      // Added, changed or deleted, here or by an agent: what the search found may be out of date.
      searchRound = searching.afterMeetingsChanged().round
    }
    .onChange(of: live == nil) { _, ended in
      // A notice about the recording that just ended has nothing left to say.
      if ended { model.meetings.lastError = nil }
    }
    .onAppear {
      if let failure = preset.startFailure { report(failure) }
      if preset.confirmsDelete { deleting = model.meetingList.first }
    }
  }

  // MARK: Meetings

  private func hasPastMeetings(liveID: Meeting.ID?) -> Bool {
    model.meetingList.contains { $0.id != liveID }
  }

  /// Everything but the meeting being recorded, narrowed to what the search found.
  private func pastMeetings(liveID: Meeting.ID?) -> [Meeting] {
    model.meetingList.filter { meeting in
      meeting.id != liveID && (found?.contains(meeting.id) ?? true)
    }
  }

  private func row(_ meeting: Meeting) -> some View {
    let phase = MeetingsLogic.phase(
      of: meeting,
      liveID: model.meetings.live?.meetingID,
      processing: model.meetings.processing
    )
    return MeetingRow(
      meeting: meeting,
      phase: phase,
      onOpen: { selection = meeting.id },
      onCopy: {
        MeetingActions.copy(meeting.markdown())
        toast = Toast("Copied")
      },
      onDelete: { deleting = meeting },
      onFix: { remedy in MeetingActions.fix(remedy, meeting.id, in: model) }
    )
  }

  /// Waits for a pause in typing, then asks the library, which also looks inside notes and
  /// transcripts. The first search is not held back, so results show as soon as typing starts.
  private func search(for text: String) async {
    guard !text.isEmpty else {
      found = nil
      return
    }
    if found != nil { try? await Task.sleep(for: .milliseconds(250)) }
    guard !Task.isCancelled else { return }
    do {
      let result = try await model.library.meetings(search: text)
      guard !Task.isCancelled else { return }
      found = Set(result.map(\.id))
    } catch {
      if !Task.isCancelled { model.errorMessage = error.localizedDescription }
    }
  }

  // MARK: Starting

  private func startButton(_ kind: SpacesButtonStyle.Kind) -> some View {
    Button(action: start) {
      Label("Start recording", systemImage: "record.circle")
    }
    .buttonStyle(.spaces(kind, size: idiom == .phone && kind == .primary ? .small : .regular))
    // Never shortened to make room for the search field beside it.
    .fixedSize()
    .disabled(isStarting)
  }

  private func start() {
    guard !isStarting else { return }
    isStarting = true
    deniedPermission = nil
    Task {
      defer { isStarting = false }
      do {
        try await model.meetings.start()
      } catch {
        report(error)
      }
    }
  }

  /// Shows why a recording could not start, in the same place the engine reports it.
  private func report(_ error: any Error) {
    if case .permissionDenied(let permission)? = error as? SpacesError {
      deniedPermission = permission
    } else {
      deniedPermission = nil
    }
    model.meetings.lastError = error.localizedDescription
  }

  // MARK: Notices

  private var hasNotices: Bool {
    model.meetings.lastError != nil || needsKey
  }

  private var needsKey: Bool {
    model.isLoaded && KeyNeed.isMissing(hasKey: model.hasAPIKey, settings: model.settings)
  }

  @ViewBuilder
  private func notices(isLive: Bool) -> some View {
    if needsKey {
      Banner(
        .warning,
        title: "Add your OpenAI key first",
        message: "Without a key in Settings, a recording cannot be turned into a transcript or notes."
      )
    }
    if let problem = model.meetings.lastError {
      // The engine reports two things here: why a recording could not start, and, while one
      // is running, that the computer's sound could not be recorded with it.
      let text = MeetingsLogic.notice(problem)
      Banner(isLive ? .warning : .error, title: text.title, message: text.message) {
        HStack(spacing: Spaces.Space.s) {
          if let permission = missingPermission(isLive: isLive) {
            Button("Allow access") {
              Task { await model.permissions.request(permission) }
            }
            .buttonStyle(.spaces(.tertiary, size: .small))
          }
          Button("Dismiss") {
            model.meetings.lastError = nil
            deniedPermission = nil
          }
          .buttonStyle(.spaces(.ghost, size: .small))
        }
      }
    }
  }

  /// The permission the notice is about, when asking for it could help.
  private func missingPermission(isLive: Bool) -> Permission? {
    let permission = isLive ? Permission.systemAudio : deniedPermission
    guard let permission, model.permissions.status(permission) != .granted else { return nil }
    return permission
  }

  @ViewBuilder
  private func emptyState(isLive: Bool) -> some View {
    if found != nil {
      EmptyState(
        "No meetings found",
        message: "Nothing matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”. "
          + "The search looks in titles, notes, tags and transcripts."
      ) {
        SymbolTile("magnifyingglass")
      } action: {
        Button("Clear search") { query = "" }
          .buttonStyle(.spaces(.tertiary))
      }
    } else if !isLive {
      EmptyState("No meetings yet", message: MeetingsLogic.firstMeetingHint(idiom)) {
        SymbolTile("waveform.and.mic")
      }
    }
  }
}

// MARK: - Row

/// One past meeting: title, when and how long, what it was about, and its badges.
private struct MeetingRow: View {
  let meeting: Meeting
  let phase: MeetingPhase
  let onOpen: () -> Void
  let onCopy: () -> Void
  let onDelete: () -> Void
  let onFix: (MeetingProblem.Remedy) -> Void

  @Environment(\.spacesIdiom) private var idiom
  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false
  /// Whether the keyboard is on the row, or on one of its actions.
  @FocusState private var isFocused: Bool
  @FocusState private var actionIsFocused: Bool

  var body: some View {
    let phone = idiom == .phone
    let hovered = isHovered || simulatedHover
    let problem = MeetingsLogic.problem(of: meeting, phase: phase)
    HStack(alignment: .center, spacing: Spaces.Space.m) {
      VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
        Text(meeting.title)
          .spacesText(.bodyStrong)
          .lineLimit(phone ? 2 : 1)
        Text(facts)
          .spacesText(.caption, color: Spaces.Color.textTertiary)
          .lineLimit(1)
        about(problem)
        if phone, problem != nil || !meeting.tags.isEmpty {
          MeetingFlow {
            badge(problem)
            tags
          }
          .padding(.top, Spaces.Space.xxs)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if !phone {
        badge(problem).layoutPriority(1)
      }
      if !phone, let problem, let remedy = problem.remedy, problem.isSevere || phase == .interrupted {
        Button(problem.actionTitle) { onFix(remedy) }
          .buttonStyle(.spaces(.tertiary, size: .small))
      }
      let showsActions = phone || hovered || isFocused || actionIsFocused
      // The tags rest where the actions show, as the app's name does on the history list.
      ZStack(alignment: .trailing) {
        if !phone { tags.opacity(showsActions ? 0 : 1) }
        actions(problem)
          // Tab reaches the actions even while they are unseen, so they show for the keyboard too.
          .focused($actionIsFocused)
          .opacity(showsActions ? 1 : 0)
          .padding(.trailing, phone ? -Spaces.Space.s : -Spaces.Space.xs)
      }
    }
    .padding(.vertical, Spaces.Space.m)
    .rowChrome(isHighlighted: hovered)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(Spaces.Motion.quick, value: isHovered)
    .animation(Spaces.Motion.quick, value: isFocused || actionIsFocused)
    .onTapGesture(perform: onOpen)
    .focusable(true, interactions: .activate)
    .focused($isFocused)
    .onKeyPress(.return) {
      onOpen()
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(meeting.title)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default, onOpen)
  }

  private func actions(_ problem: MeetingProblem?) -> some View {
    HStack(spacing: Spaces.Space.xxs) {
      if idiom == .mac { IconButton("doc.on.doc", label: "Copy", action: onCopy) }
      OverflowMenu(label: "More for \(meeting.title)") {
        Button("Open", action: onOpen)
        if let problem, let remedy = problem.remedy { Button(problem.actionTitle) { onFix(remedy) } }
        Button("Copy", action: onCopy)
        Divider()
        Button("Delete", role: .destructive, action: onDelete)
      }
    }
  }

  private var facts: String {
    let open = MeetingsLogic.openActionItems(in: meeting)
    return [
      MeetingsLogic.when(meeting.startedAt), MeetingsLogic.length(meeting.duration),
      open > 0 ? "\(open) to do" : nil,
    ]
    .compactMap { $0 }
    .joined(separator: " · ")
  }

  /// The tags as one quiet line of text. They are for finding a meeting, not for reading the list.
  @ViewBuilder private var tags: some View {
    if !meeting.tags.isEmpty {
      Text(MeetingsLogic.tagLine(meeting.tags))
        .spacesText(.caption, color: Spaces.Color.textTertiary)
        .lineLimit(1)
        .accessibilityLabel("Tags: \(meeting.tags.joined(separator: ", "))")
    }
  }

  /// The third line: what is happening to the meeting, what went wrong, or what it was about.
  @ViewBuilder
  private func about(_ problem: MeetingProblem?) -> some View {
    if phase == .processing {
      HStack(spacing: Spaces.Space.s) {
        ProcessingIndicator(tint: Spaces.Color.accent, height: 14)
        Text("Writing notes…").spacesText(.caption)
      }
    } else if let problem, problem.isSevere || phase == .interrupted {
      Text(problem.title)
        .spacesText(.caption)
        .lineLimit(idiom == .phone ? 2 : 1)
    } else if let preview = MeetingsLogic.preview(of: meeting) {
      Text(preview)
        .spacesText(.caption)
        .lineLimit(idiom == .phone ? 2 : 1)
    }
  }

  /// The one badge a row can have: something went wrong with this meeting.
  @ViewBuilder
  private func badge(_ problem: MeetingProblem?) -> some View {
    if let problem {
      if problem.isSevere {
        Badge("Could not finish", tone: .danger)
      } else if phase == .interrupted {
        Badge("Cut short", tone: .warning)
      } else {
        Badge(problem.remedy == .writeNotes ? "No notes" : "Part missing", tone: .warning)
      }
    }
  }
}

// MARK: - Live card

/// The meeting being recorded: a running clock, the voice level, the last lines heard, Stop.
private struct MeetingLiveCard: View {
  let title: String
  let live: MeetingEngine.Live
  let showsLevel: Bool
  let onOpen: () -> Void
  let onStop: () -> Void

  @Environment(\.spacesIdiom) private var idiom
  @State private var isStopping = false

  var body: some View {
    let phone = idiom == .phone
    Card(padding: 0) {
      VStack(alignment: .leading, spacing: Spaces.Space.m) {
        HStack(alignment: .center, spacing: Spaces.Space.m) {
          VStack(alignment: .leading, spacing: Spaces.Space.xs) {
            MeetingRecordingStamp(startedAt: live.startedAt)
            Text(title)
              .spacesText(.cardTitle)
              .lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if showsLevel { MeetingLevelMeter() }
          if !phone { stopButton(fullWidth: false) }
        }
        Hairline()
        MeetingLiveLines(segments: live.segments)
        if phone { stopButton(fullWidth: true) }
      }
      .padding(phone ? Spaces.Space.l : 20)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Open this meeting", onOpen)
  }

  private func stopButton(fullWidth: Bool) -> some View {
    Button {
      isStopping = true
      onStop()
    } label: {
      Label("Stop", systemImage: "stop.fill")
    }
    .buttonStyle(.spaces(.primary, fullWidth: fullWidth))
    .disabled(isStopping)
    .accessibilityLabel("Stop recording")
  }
}

/// The newest lines of a live transcript, kept at the bottom as more arrive.
private struct MeetingLiveLines: View {
  let segments: [TranscriptSegment]
  @Environment(\.spacesIdiom) private var idiom

  var body: some View {
    let turns = MeetingsLogic.turns(segments).suffix(4)
    ScrollView {
      VStack(alignment: .leading, spacing: Spaces.Space.s) {
        if turns.isEmpty {
          Text("Listening…").spacesText(.body, color: Spaces.Color.textSecondary)
        }
        ForEach(turns) { turn in
          let name = Text(turn.speaker.label)
            .foregroundStyle(turn.speaker == .me ? Spaces.Color.accent : Spaces.Color.textSecondary)
          let words = turn.segments.map(\.text).joined(separator: " ")
          if idiom == .phone {
            // No room for a column of names: the name leads the line.
            Text("\(name.fontWeight(.medium))  \(words)")
              .spacesText(.body)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            HStack(alignment: .firstTextBaseline, spacing: Spaces.Space.m) {
              name
                .spacesText(.captionStrong)
                .lineLimit(1)
                .frame(width: MeetingsMetrics.speakerColumn, alignment: .leading)
              Text(words)
                .spacesText(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .defaultScrollAnchor(.bottom)
    .scrollDisabled(true)
    .frame(height: MeetingsMetrics.liveLinesHeight(idiom))
    // Older lines fade out at the top instead of being cut through.
    .mask {
      LinearGradient(
        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Live transcript")
  }
}
