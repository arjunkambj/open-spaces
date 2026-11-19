import SwiftUI
import WisperDomain
import WisperEngine

/// The list of meetings: start a recording, watch the live one, find and open past ones.
struct MeetingsList: View {
  @Binding var selection: Meeting.ID?
  /// False while an open meeting covers the list. The live waveform rests then.
  private let isShown: Bool
  private let preset: MeetingsPreset

  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom
  @AppStorage("meetings.explainerDismissed") private var explainerDismissed = false

  @State private var query: String
  /// The meetings the search found. `nil` while nothing is being searched for.
  @State private var found: Set<Meeting.ID>?
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
    Page(title: "Meetings") {
      if idiom == .mac, hasPastMeetings(liveID: live?.meetingID) {
        SearchField(text: $query, placeholder: "Search meetings")
      }
      if live == nil { startButton(.primary) }
    } content: {
      if hasNotices { VStack(spacing: Wisper.Space.m) { notices(isLive: live != nil) } }
      if let live {
        // The stored title, so a rename made while recording shows here too.
        let title = model.meetingList.first { $0.id == live.meetingID }?.title ?? live.title
        MeetingLiveCard(title: title, live: live, showsLevel: isShown) {
          selection = live.meetingID
        } onStop: {
          Task { await model.meetings.stop() }
        }
      } else if preset.showsExplainer ?? !explainerDismissed {
        explainer
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
    .task(id: query) { await search() }
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
        toast = Toast("Copied as Markdown")
      },
      onDelete: { deleting = meeting },
      onFix: { remedy in MeetingActions.fix(remedy, meeting.id, in: model) }
    )
  }

  /// Waits for a pause in typing, then asks the library, which also looks inside notes and
  /// transcripts. The first search is not held back, so results show as soon as typing starts.
  private func search() async {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      found = nil
      return
    }
    if found != nil { try? await Task.sleep(for: .milliseconds(250)) }
    guard !Task.isCancelled, let result = try? await model.library.meetings(search: text) else { return }
    guard !Task.isCancelled else { return }
    found = Set(result.map(\.id))
  }

  // MARK: Starting

  private func startButton(_ kind: WisperButtonStyle.Kind) -> some View {
    Button(action: start) {
      Label("Start recording", systemImage: "record.circle")
    }
    .buttonStyle(.wisper(kind, size: idiom == .phone && kind == .primary ? .small : .regular))
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
    if case .permissionDenied(let permission)? = error as? WisperError {
      deniedPermission = permission
    } else {
      deniedPermission = nil
    }
    model.meetings.lastError = error.localizedDescription
  }

  // MARK: Notices

  private var hasNotices: Bool {
    model.meetings.lastError != nil || (model.isLoaded && !model.hasAPIKey)
  }

  @ViewBuilder
  private func notices(isLive: Bool) -> some View {
    if model.isLoaded, !model.hasAPIKey {
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
        HStack(spacing: Wisper.Space.s) {
          if let permission = missingPermission(isLive: isLive) {
            Button("Allow access") {
              Task { await model.permissions.request(permission) }
            }
            .buttonStyle(.wisper(.tertiary, size: .small))
          }
          Button("Dismiss") {
            model.meetings.lastError = nil
            deniedPermission = nil
          }
          .buttonStyle(.wisper(.ghost, size: .small))
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

  private var explainer: some View {
    let sound =
      idiom == .phone
      ? "Open Wisper records your microphone."
      : "Open Wisper records your microphone and the sound your Mac plays, so both sides of a call "
        + "are captured."
    return HeroCard(
      "Every meeting, written down.",
      message: sound
        + " The recording goes to OpenAI with your own key to become text. The transcript and notes "
        + "are stored only on this device. Tell people before you record them."
    ) {
      startButton(.primary)
    }
    .onDismiss { explainerDismissed = true }
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
          .buttonStyle(.wisper(.tertiary))
      }
    } else if !isLive {
      EmptyState(
        "No meetings yet",
        message: "Record a meeting and its transcript and notes show up here."
      ) {
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

  @Environment(\.wisperIdiom) private var idiom
  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false

  var body: some View {
    let phone = idiom == .phone
    let hovered = isHovered || simulatedHover
    let problem = MeetingsLogic.problem(of: meeting, phase: phase)
    HStack(alignment: .center, spacing: Wisper.Space.m) {
      VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
        Text(meeting.title)
          .wisperText(.bodyStrong)
          .lineLimit(phone ? 2 : 1)
        Text(facts)
          .wisperText(.caption, color: Wisper.Color.textTertiary)
          .lineLimit(1)
        about(problem)
        if phone {
          MeetingFlow { badges(problem) }
            .padding(.top, Wisper.Space.xs)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if !phone {
        HStack(spacing: Wisper.Space.xs) { badges(problem) }
          .layoutPriority(1)
      }
      if !phone, let problem, problem.isSevere || phase == .interrupted {
        Button(problem.actionTitle) { onFix(problem.remedy) }
          .buttonStyle(.wisper(.tertiary, size: .small))
      }
      HStack(spacing: Wisper.Space.xxs) {
        if !phone { IconButton("doc.on.doc", label: "Copy as Markdown", action: onCopy) }
        OverflowMenu(label: "More for \(meeting.title)") {
          Button("Open", action: onOpen)
          if let problem { Button(problem.actionTitle) { onFix(problem.remedy) } }
          Button("Copy as Markdown", action: onCopy)
          Divider()
          Button("Delete", role: .destructive, action: onDelete)
        }
      }
      .opacity(phone || hovered ? 1 : 0)
    }
    .padding(.horizontal, Wisper.Space.l)
    .padding(.vertical, Wisper.Space.m)
    .background(hovered ? Wisper.Color.surfaceHover : .clear)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(Wisper.Motion.quick, value: isHovered)
    .onTapGesture(perform: onOpen)
    .focusable(true, interactions: .activate)
    .onKeyPress(.return) {
      onOpen()
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(meeting.title)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default, onOpen)
  }

  private var facts: String {
    [MeetingsLogic.when(meeting.startedAt), MeetingsLogic.length(meeting.duration)]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  /// The third line: what is happening to the meeting, what went wrong, or what it was about.
  @ViewBuilder
  private func about(_ problem: MeetingProblem?) -> some View {
    if phase == .processing {
      HStack(spacing: Wisper.Space.s) {
        ProcessingIndicator(tint: Wisper.Color.accent, height: 14)
        Text("Writing notes…").wisperText(.caption)
      }
    } else if let problem, problem.isSevere || phase == .interrupted {
      Text(problem.title)
        .wisperText(.caption)
        .lineLimit(idiom == .phone ? 2 : 1)
    } else if let preview = MeetingsLogic.preview(of: meeting) {
      Text(preview)
        .wisperText(.caption)
        .lineLimit(idiom == .phone ? 2 : 1)
    }
  }

  @ViewBuilder
  private func badges(_ problem: MeetingProblem?) -> some View {
    if let problem {
      if problem.isSevere {
        Badge("Could not finish", tone: .danger)
      } else if phase == .interrupted {
        Badge("Cut short", tone: .warning)
      } else {
        Badge(problem.remedy == .writeNotes ? "No notes" : "Part missing", tone: .warning)
      }
    }
    let open = MeetingsLogic.openActionItems(in: meeting)
    if open > 0 { Badge("\(open) to do", tone: .accent) }
    ForEach(meeting.tags.prefix(3), id: \.self) { tag in Badge(tag) }
    if meeting.tags.count > 3 { Badge("+\(meeting.tags.count - 3)") }
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

  @Environment(\.wisperIdiom) private var idiom
  @State private var isStopping = false

  var body: some View {
    let phone = idiom == .phone
    Card(padding: 0) {
      VStack(alignment: .leading, spacing: Wisper.Space.m) {
        HStack(alignment: .center, spacing: Wisper.Space.m) {
          VStack(alignment: .leading, spacing: Wisper.Space.xs) {
            MeetingRecordingStamp(startedAt: live.startedAt)
            Text(title)
              .wisperText(.cardTitle)
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
      .padding(phone ? Wisper.Space.l : 20)
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
    .buttonStyle(.wisper(.primary, fullWidth: fullWidth))
    .disabled(isStopping)
    .accessibilityLabel("Stop recording")
  }
}

/// The newest lines of a live transcript, kept at the bottom as more arrive.
private struct MeetingLiveLines: View {
  let segments: [TranscriptSegment]
  @Environment(\.wisperIdiom) private var idiom

  var body: some View {
    let turns = MeetingsLogic.turns(segments).suffix(4)
    ScrollView {
      VStack(alignment: .leading, spacing: Wisper.Space.s) {
        if turns.isEmpty {
          Text("Listening…").wisperText(.body, color: Wisper.Color.textSecondary)
        }
        ForEach(turns) { turn in
          let name = Text(turn.speaker.label)
            .foregroundStyle(turn.speaker == .me ? Wisper.Color.accent : Wisper.Color.textSecondary)
          let words = turn.segments.map(\.text).joined(separator: " ")
          if idiom == .phone {
            // No room for a column of names: the name leads the line.
            Text("\(name.fontWeight(.medium))  \(words)")
              .wisperText(.body)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            HStack(alignment: .firstTextBaseline, spacing: Wisper.Space.m) {
              name
                .wisperText(.captionStrong)
                .lineLimit(1)
                .frame(width: MeetingsMetrics.speakerColumn, alignment: .leading)
              Text(words)
                .wisperText(.body)
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
