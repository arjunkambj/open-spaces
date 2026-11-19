# Open Wisper: guide for agents and contributors

Open Wisper is an open-source voice dictation and meeting-notes app for macOS and iOS. Hold a key, speak, and clean text lands in whatever app you are typing in. It also records meetings and writes notes. It is local-first: no account, no server, no database. The user brings their own OpenAI API key.

## Rules that never bend

- **Everything is stored on the device.** Files under the data folder, the API key in the Keychain. No cloud, no analytics, no telemetry, no sign-up. The only network calls go to the OpenAI-compatible server the user configured.
- **One branch, one environment.** `main` is the base branch. There is no staging or dev environment. Work on a branch, open a PR into `main`.
- **Original work only.** The layout and flows are inspired by popular dictation apps, but never copy another product's code, images, icons, sounds, name or wording.
- **No third-party Swift dependencies** without a strong reason. Apple frameworks and the standard library cover what we need.
- The API key never goes into a file, a log, an error message or a test.

## Layout

```
apps/macos        macOS app (SwiftPM; scripts/bundle makes the .app)
apps/ios          iOS app + keyboard extension (XcodeGen project.yml)
packages/domain   WisperDomain   models, the seams (protocols), in-memory fakes
packages/store    WisperStore    FileLibrary, KeychainSecretStore
packages/ai       WisperAI       OpenAI adapters
packages/audio    WisperAudio    microphone + system-audio capture
packages/engine   WisperEngine   DictationEngine, MeetingEngine, AppModel
packages/ui       WisperUI       design tokens + SwiftUI components (both platforms)
packages/agent    WisperAgent    MCP server + `wisper` command-line tool
scripts           swiftw, ios, ci-try and other build helpers
docs              agents.md (connecting an agent), data-format.md (files on disk)
```

Turborepo (`turbo.json`) runs each package's `build`, `test` and `lint` scripts; pnpm workspaces declare the dependency graph. The code is Swift 6 with strict concurrency.

Dependencies point one way: `domain` knows nothing; `store`, `ai`, `audio`, `engine`, `ui`, `agent` depend on `domain` (and `ui` on `engine`, `agent` on `store`); the apps depend on everything and are the only place real adapters are wired together.

## Design: deep modules

We design **deep modules**: a lot of behaviour behind a small interface.

- The seams are the protocols in `packages/domain/Sources/WisperDomain/Seams.swift`: `Library`, `SecretStore`, `Transcriber`, `LanguageModel`, `AudioCapture`, `TextTarget`, `Permissions`. Each has a real adapter and an in-memory adapter (`Fakes.swift`). Two adapters make a seam real; do not add a protocol with one.
- `DictationEngine` and `MeetingEngine` each hide a whole pipeline behind a handful of methods. Screens never talk to a transcriber or a file.
- `AppModel` is the one object screens use. It holds a live copy of the library, so a change made by an agent through the `wisper` tool shows up in the app.
- Test through the interface, with the fakes. If a test needs to reach inside a module, the module has the wrong shape.
- Accept dependencies, do not create them. Return results instead of hiding side effects.
- Before adding a type, ask the deletion test: if it were deleted, would complexity vanish (it was a pass-through) or spread across callers (it earns its keep)?

Vocabulary: module, interface, implementation, seam, adapter, depth. Avoid "service", "manager", "helper", "boundary".

## Commands

```bash
pnpm install            # once
pnpm check              # lint + build + test, everything
pnpm test               # tests only
pnpm format             # format all Swift in place
pnpm mac                # build, bundle and open the macOS app

# One package:
cd packages/engine && ../../scripts/swiftw build && ../../scripts/swiftw test
swift format lint --strict --recursive --parallel packages apps
```

Always call `scripts/swiftw` instead of `swift` for build/test/run. It makes the build work on a Mac that has only the Command Line Tools (it picks an SDK whose compiler plugins are present and adds the Swift Testing plugin path).

Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest.

The iOS app cannot be built without full Xcode: `scripts/ios <generate|build|test>` (also `pnpm ios:build`, `pnpm ios:test`) skips with a message when Xcode is missing, and CI builds it. To build an uncommitted working tree in CI: `scripts/ci-try <name>` pushes a snapshot to the throwaway branch `ci/try-<name>`; delete that branch when you are done (`git push origin --delete ci/try-<name>`).

CI compiles with Xcode 26.6 (Swift 6.3), which can be older than your local Swift. Do not lean on behaviour that only the newest compiler has.

## Style

- 2-space indent, 110 columns, `swift format` clean with `--strict` (config in `.swift-format`).
- SwiftUI with the Observation framework (`@Observable`, `@Environment(AppModel.self)`), not `ObservableObject`.
- UI code is `@MainActor`. Long work is `async`; never block the main thread.
- Errors people see are `WisperError` with plain-English messages.
- Text shown to people is plain English: short sentences, no jargon.
- Colours, fonts, spacing and radii come from `WisperUI` tokens, never literals in a screen.
- Support light and dark mode, Dynamic Type on iOS, VoiceOver labels on every control.
- Doc comments (`///`) on public declarations say what a caller must know, not how it works inside.

## Commits and PRs

One commit per feature, holding everything that feature needs. A fix is its own commit, named for the feature it fixes. PRs go into `main`.

## Data on disk

The data folder is `~/Library/Application Support/Open Wisper` (override with `OPEN_WISPER_HOME`). Everything in it is JSON, Markdown or audio that a person or an agent can read. See `docs/data-format.md`.
