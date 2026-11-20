# Spaces: guide for agents and contributors

Spaces is an open-source voice dictation and meeting-notes app for macOS and iOS. Hold a key, speak, and clean text lands in whatever app you are typing in. It also records meetings and writes notes. It is local-first: no account, no server, no database. The user brings their own OpenAI API key.

## Rules that never bend

- **Everything is stored on the device.** Files under the data folder, the API keys in their own private file (`api-key.json`), not the Keychain. No cloud, no analytics, no telemetry, no sign-up, no database. The only network calls go to the OpenAI-compatible server the user configured, to Anthropic when the text model is a Claude model, plus the Mac app's check for a new version on GitHub (about once a day; it sends no user data).
- **One branch, one environment.** `main` is the base branch. There is no staging or dev environment. Work on a branch, open a PR into `main`.
- **Original work only.** The layout and flows are inspired by popular dictation apps, but never copy another product's code, images, icons, sounds, name or wording.
- **No third-party Swift dependencies** without a strong reason. Apple frameworks and the standard library cover what we need. The one exception is Sparkle, the updater in the Mac app, imported in a single file (`AppUpdater.swift`).
- An API key never goes into any file but `api-key.json`, a log or an error message.
- **No tests, no legacy, no fallbacks.** No test suites. No code kept for old callers or old data: change the callers instead. No second path in case the first one fails: fail plainly, with a clear `SpacesError`.

## Layout

```
apps/macos        macOS app (SwiftPM; scripts/bundle makes the .app)
apps/ios          iOS app, keyboard and widget extensions: thin Xcode targets (XcodeGen project.yml)
apps/ios/Phone    SpacesPhone, SpacesKeyboard, SpacesLive   nearly all iOS code; a package that builds on a Mac
apps/web          the website whisper.0xhoney.com (TanStack Start + Tailwind, prerendered; on Cloudflare)
packages/domain   SpacesDomain   models, the seams (protocols), in-memory fakes, APIServer, LinkTicket
packages/store    SpacesStore    FileLibrary, FileSecretStore
packages/ai       SpacesAI       OpenAI and Anthropic adapters, ModelRouter
packages/audio    SpacesAudio    microphone + system-audio capture
packages/engine   SpacesEngine   DictationEngine, MeetingEngine, AppModel
packages/ui       SpacesUI       design tokens + SwiftUI components (both platforms)
packages/agent    SpacesAgent    MCP server + `spaces` command-line tool
scripts           swiftw, ios, ci-try and other build helpers
docs              agents.md (connecting an agent), data-format.md (files on disk)
```

Turborepo (`turbo.json`) runs each package's `build` and `lint` scripts; pnpm workspaces declare the dependency graph. The code is Swift 6 with strict concurrency.

Dependencies point one way: `domain` knows nothing; `store`, `ai`, `audio`, `engine`, `ui`, `agent` depend on `domain` (and `ui` on `engine`, `agent` on `store`); the apps depend on everything and are the only place real adapters are wired together.

## Contracts every change keeps

- **Server address.** Resolve it with `Settings.apiServer()` (`APIServer`). An address that is set but unusable throws `SpacesError.invalidServerAddress`: send nothing, and never fall back to OpenAI.
- **API keys.** One key per host. Read it with `SecretStore.apiKey(for: server.host)` and save it with `setAPIKey(_:host:)`, so a key is only ever sent to the server it was saved for. Claude models (`Settings.isClaude`) always go to `APIServer.anthropic` with the key saved for `api.anthropic.com`; the custom server address never applies to them. Speech to text is OpenAI only.
- **Links.** A link that starts listening or stops a recording (`SpacesLink.needsTrust`) is followed only with a redeemed `LinkTicket` or the user's yes. A sender of ours (the `spaces` tool, the iOS keyboard) attaches one with `LinkTicket.issue`. Without a ticket: starting a meeting asks first, dictation and stop links are ignored.
- **Nothing said is lost.** A failed dictation keeps its audio and a history entry to retry. A meeting's audio stays on disk until all of it is transcribed, and `recoverUnfinished` rebuilds from it after a crash.
- **Agent export.** `meetings export` writes only a new `.md` file. Keep the rules in `docs/agents.md` ("Safety") true.
- **Updates.** The Mac app updates itself through Sparkle from GitHub Releases. Every release is signed with the same certificate and update key (`scripts/setup-signing`), so permissions survive an update and a tampered download is refused. A release is a `vX.Y.Z` tag that matches `apps/macos/package.json`; see CONTRIBUTING.md.
- **Docs follow the code.** A change to a stored model updates `docs/data-format.md`. A change to a `spaces` tool updates the tables in `docs/agents.md`: paste the output of `spaces tools --markdown` between the markers.

## Design: deep modules

We design **deep modules**: a lot of behaviour behind a small interface.

- The seams are the protocols in `packages/domain/Sources/SpacesDomain/Seams.swift`: `Library`, `SecretStore`, `Transcriber`, `LanguageModel`, `AudioCapture`, `TextTarget`, `Permissions`. Each has a real adapter and an in-memory adapter (`Fakes.swift`) that demo mode and the snapshot tools run on. Two adapters make a seam real; do not add a protocol with one.
- `DictationEngine` and `MeetingEngine` each hide a whole pipeline behind a handful of methods. Screens never talk to a transcriber or a file.
- `AppModel` is the one object screens use. It holds a live copy of the library, so a change made by an agent through the `spaces` tool shows up in the app.
- Callers go through the interface. If one needs to reach inside a module, the module has the wrong shape.
- Accept dependencies, do not create them. Return results instead of hiding side effects.
- Before adding a type, ask the deletion test: if it were deleted, would complexity vanish (it was a pass-through) or spread across callers (it earns its keep)?

Vocabulary: module, interface, implementation, seam, adapter, depth. Avoid "service", "manager", "helper", "boundary".

## Commands

```bash
pnpm install            # once
pnpm check              # lint + build, everything
pnpm format             # format all Swift in place
pnpm mac                # build, bundle and open the macOS app
pnpm web                # the website on 127.0.0.1:4321; web:build builds it, web:deploy puts it on Cloudflare

# One package:
cd packages/engine && ../../scripts/swiftw build
cd apps/ios/Phone && ../../../scripts/swiftw build
swift format lint --strict --recursive --parallel packages apps

# Look at screens as PNG files, with no window opened:
cd packages/ui && ../../scripts/swiftw run spaces-snapshots <folder>              # shared screens
cd apps/ios/Phone && ../../../scripts/swiftw run spaces-phone-snapshots <folder>  # iPhone screens
"apps/macos/build/Spaces.app/Contents/MacOS/SpacesApp" --snapshots <folder> # Mac screens
```

The website is the one part that is not Swift. Its words are all in `apps/web/src/content.ts`; say only what the README says is true. It is prerendered to plain HTML that reads in full without its scripts, and it loads nothing from other sites: no analytics, no cookies, no fonts or scripts from elsewhere. Keep it so. `apps/web/README.md` has the rest.

The Mac app also starts with `--demo`: made-up data, no microphone, saved key, shortcuts or network.

Always call `scripts/swiftw` instead of `swift` for build and run. It makes the build work on a Mac that has only the Command Line Tools (it picks an SDK whose compiler plugins are present).

The iOS app cannot be built without full Xcode: `scripts/ios <generate|build>` (also `pnpm ios:build`) skips with a message when Xcode is missing, and CI builds it. To build an uncommitted working tree in CI: `scripts/ci-try <name>` pushes a snapshot to the throwaway branch `ci/try-<name>`; delete that branch when you are done (`git push origin --delete ci/try-<name>`).

CI runs on `macos-26` with Xcode 26.6 (Swift 6.3), which can be older than your local Swift. Write code that the older compiler accepts. CI takes iOS screenshots only on a run started by hand (Actions > CI > Run workflow) or from `scripts/ci-try ios`.

## Style

- 2-space indent, 110 columns, `swift format` clean with `--strict` (config in `.swift-format`).
- SwiftUI with the Observation framework (`@Observable`, `@Environment(AppModel.self)`), not `ObservableObject`.
- UI code is `@MainActor`. Long work is `async`; never block the main thread.
- Errors people see are `SpacesError` with plain-English messages.
- Text shown to people is plain English: short sentences, no jargon.
- Colours, fonts, spacing and radii come from `SpacesUI` tokens, never literals in a screen.
- Support light and dark mode, Dynamic Type on iOS, VoiceOver labels on every control.
- Doc comments (`///`) on public declarations say what a caller must know, not how it works inside.

## Commits and PRs

One commit per feature, holding everything that feature needs. A fix is its own commit, named for the feature it fixes. PRs go into `main`.

## Data on disk

The data folder is `~/Library/Application Support/Spaces` (override with `SPACES_HOME`). Everything in it is JSON, Markdown or audio that a person or an agent can read. See `docs/data-format.md`.
