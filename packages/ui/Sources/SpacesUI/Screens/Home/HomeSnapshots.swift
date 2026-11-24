import SpacesDomain
import SpacesEngine
import SwiftUI

/// Snapshot cases for this area. See `SnapshotCase`.
enum HomeSnapshots {
  @MainActor static var cases: [SnapshotCase] {
    let states = stateSamples()
    let long = longSample()
    return [
      SnapshotCase("home") { HomeScreen(preview: HomePreview(hoveredRow: 1)) },
      SnapshotCase("home-narrow", canvas: .custom(width: 640, height: 720)) {
        HomeScreen().background(Spaces.Color.panel)
      },
      SnapshotCase("home-empty", model: { ScreenSamples.model() }) { HomeScreen() },
      SnapshotCase("home-no-key", model: { .demo(hasAPIKey: false) }) { HomeScreen() },
      // A server of the person's own may not need a key: no warning.
      SnapshotCase(
        "home-server-no-key",
        model: {
          ScreenSamples.model(
            settings: .init(userName: "Alex", onboardedAt: Date(), apiBaseURL: "http://localhost:11434/v1"),
            dictations: states,
            hasAPIKey: false
          )
        }
      ) { HomeScreen() },
      SnapshotCase("home-search") { HomeScreen(preview: HomePreview(query: "review")) },
      SnapshotCase("home-no-results") { HomeScreen(preview: HomePreview(query: "giraffe")) },
      SnapshotCase("home-states", model: { ScreenSamples.model(dictations: states) }) {
        HomeScreen(
          preview: HomePreview(
            hoveredRow: 1,
            player: HomeAudioPlayer(showing: states[0].id, progress: 0.4, elapsed: 3)
          )
        )
      },
      SnapshotCase("home-long", model: { ScreenSamples.model(dictations: long) }) {
        HomeScreen()
      },
      SnapshotCase("home-delete", model: { ScreenSamples.model(dictations: states) }) {
        HomeScreen(preview: HomePreview(deleting: states[0]))
      },
      // Its server stopped a while ago: when it was last used, with an empty dot.
      SnapshotCase(
        "home-agent-last-used",
        model: {
          ScreenSamples.model(dictations: SampleData.dictations(), agents: agentSamples(connected: false))
        }
      ) { HomeScreen() },
      SnapshotCase(
        "home-agents-narrow",
        canvas: .custom(width: 640, height: 720),
        model: {
          ScreenSamples.model(dictations: SampleData.dictations(), agents: agentSamples(connected: true))
        }
      ) { HomeScreen().background(Spaces.Color.panel) },
      SnapshotCase(
        "home-agents-wide",
        canvas: .custom(width: 1_280, height: 720),
        model: {
          ScreenSamples.model(dictations: SampleData.dictations(), agents: agentSamples(connected: true))
        }
      ) { HomeScreen().background(Spaces.Color.panel) },
    ]
  }

  /// One of each kind of row: with a recording (playing), command mode, failed, long.
  private static func stateSamples(now: Date = Date()) -> [Dictation] {
    [
      Dictation(
        createdAt: now.addingTimeInterval(-300),
        rawText: "Sounds good, I'll take a look at the pull request after lunch.",
        text: "Sounds good, I'll take a look at the pull request after lunch.",
        duration: 7,
        appName: "Slack",
        audioFile: "one.m4a"
      ),
      Dictation(
        createdAt: now.addingTimeInterval(-1_500),
        mode: .command,
        rawText: "make this shorter and friendlier",
        text: "Thanks for the quick turnaround. Thursday at 3 works for me.",
        duration: 3,
        appName: "Mail",
        audioFile: "two.m4a"
      ),
      Dictation(
        createdAt: now.addingTimeInterval(-2_400),
        rawText: "",
        text: "",
        duration: 12,
        appName: "Notes",
        audioFile: "three.m4a",
        failure: SpacesError.network("The request timed out.").errorDescription
      ),
      Dictation(
        createdAt: now.addingTimeInterval(-3_000),
        rawText: "",
        text: "",
        duration: 4,
        appName: "Visual Studio Code",
        failure: SpacesError.rateLimited.errorDescription
      ),
      // Left behind when the app quit in the middle of a dictation. The engine's own words.
      Dictation(
        createdAt: now.addingTimeInterval(-3_300),
        rawText: "",
        text: "",
        duration: 9,
        appName: "Messages",
        audioFile: "five.m4a",
        failure: "Spaces closed before this dictation was finished. Try it again."
      ),
      Dictation(
        createdAt: now.addingTimeInterval(-86_400 - 600),
        rawText: "",
        text:
          "Here is the plan for the launch post. Start with the problem people have today, which is that "
          + "typing is slow and breaks your train of thought. Then show the demo, with one short clip of "
          + "dictating into a chat app and one of writing an email. After that, explain how it stays on "
          + "your own device and uses your own key. End with the roadmap and a thank you to the people "
          + "who tested the early builds and sent notes.",
        duration: 41,
        appName: "Notes",
        audioFile: "four.m4a"
      ),
    ]
  }

  /// Claude Code and Codex. `connected: false` leaves only a Claude Code that stopped 40 minutes ago.
  private static func agentSamples(connected: Bool, now: Date = Date()) -> [AgentSession] {
    let stopped = now.addingTimeInterval(-2_400)
    let claude = AgentSession(
      pid: 4_242,
      client: AgentClient(name: "claude-code", version: "2.1.0"),
      startedAt: now.addingTimeInterval(-7_200),
      lastActiveAt: connected ? now.addingTimeInterval(-60) : stopped,
      lastTool: "meetings_get",
      endedAt: connected ? nil : stopped
    )
    guard connected else { return [claude] }
    return [
      claude,
      AgentSession(
        pid: 5_151,
        client: AgentClient(name: "codex-mcp-client", version: "0.9.2"),
        startedAt: now.addingTimeInterval(-900),
        lastActiveAt: now.addingTimeInterval(-600)
      ),
    ]
  }

  /// A long history, to see how many days and rows sit together.
  private static func longSample(now: Date = Date()) -> [Dictation] {
    let lines = [
      "Can you send me the latest numbers before the call?",
      "Add a note to follow up with the design team about the new icons.",
      "Thanks, that works. See you at ten.",
      "The build is green again after the storage fix, so we can ship the beta this afternoon.",
      "Remind me to renew the domain next week.",
      "Let's keep the first version small and add the rest after we hear from people.",
    ]
    let apps = ["Slack", "Notes", "Messages", "Linear", "Mail", "Safari"]
    return (0..<240).map { index in
      Dictation(
        createdAt: now.addingTimeInterval(-Double(index) * 5_400 - 900),
        rawText: lines[index % lines.count],
        text: lines[index % lines.count],
        duration: 5,
        appName: apps[index % apps.count]
      )
    }
  }
}

/// Made-up app models for the snapshot cases of the Home, Tasks, Dictionary, Snippets and Style screens.
@MainActor
enum ScreenSamples {
  /// An app model with exactly the given content, on in-memory fakes.
  static func model(
    settings: SpacesDomain.Settings = .init(userName: "Alex", onboardedAt: Date()),
    words: [DictionaryWord] = [],
    snippets: [Snippet] = [],
    dictations: [Dictation] = [],
    agents: [AgentSession] = [],
    tasks: TaskList = TaskList(),
    hasAPIKey: Bool = true
  ) -> AppModel {
    AppModel(
      AppModel.Dependencies(
        library: InMemoryLibrary(
          settings: settings,
          words: words,
          snippets: snippets,
          dictations: dictations,
          agents: agents,
          tasks: tasks
        ),
        secrets: InMemorySecretStore(apiKey: hasAPIKey ? "sk-demo" : nil),
        capture: FakeAudioCapture(),
        transcriber: FakeTranscriber(text: "This is a demo dictation."),
        languageModel: FakeLanguageModel(text: "This is a demo dictation."),
        target: FakeTextTarget(),
        permissions: FakePermissions(),
        checkAPIKey: { _ in },
        checkClaudeKey: { _ in }
      )
    )
  }
}
