# Contributing to Open Wisper

Thanks for wanting to help. This page tells you how to set up, how the code is shaped, and how to send a change.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to help

- **Report a bug** or **suggest a feature**: [open an issue](https://github.com/arjunkambj/open-wisper/issues/new/choose).
- **Fix or build something**: for anything bigger than a small fix, open an issue first so we can agree on the idea before you spend time on it.
- **Security problems** are reported privately. See [SECURITY.md](SECURITY.md).

## Set up

You need a Mac with macOS 14.4 or newer, Apple's Command Line Tools (`xcode-select --install`) or Xcode, Node.js 22 or newer, and pnpm 12.

```bash
git clone https://github.com/arjunkambj/open-wisper.git
cd open-wisper
pnpm install
pnpm mac        # build and open the macOS app
```

The first build takes a few minutes. The app lands in `apps/macos/build/Open Wisper.app`.

macOS ties the permissions you give (Microphone, Accessibility, System Audio Recording) to one exact build, so after a rebuild they can stop working until you remove the app from each list and add it again. If you rebuild often, sign with a certificate you make yourself. It takes a few minutes, and the steps are at the top of `apps/macos/scripts/bundle`.

To look at the app without touching your real data, microphone or key, start it on made-up data:

```bash
"apps/macos/build/Open Wisper.app/Contents/MacOS/OpenWisper" --demo
```

The iPhone app also needs full Xcode and XcodeGen (`brew install xcodegen`). Run `pnpm ios:generate`, then open `apps/ios/OpenWisper.xcodeproj` with Xcode. [apps/ios/README.md](apps/ios/README.md) has the rest. Without Xcode you can still work on everything else, and on most of the iPhone code too: it lives in a package, `apps/ios/Phone`, that builds and runs its tests on any Mac. Our CI builds the iPhone app itself on every pull request.

You do not need an OpenAI key to work on the code. The tests never call OpenAI.

## The one command to run before you push

```bash
pnpm check
```

It runs the style check, the build and the tests for every part. Our CI runs the same command, so if it passes for you it should pass there. Runs after the first are quick, because parts that did not change are skipped.

Other commands:

```bash
pnpm test       # tests only
pnpm lint       # style check only
pnpm format     # fix the style in place

# Work on one part:
cd packages/engine
../../scripts/swiftw build
../../scripts/swiftw test

# Draw the screens to PNG files, without opening a window:
cd packages/ui
../../scripts/swiftw run wisper-snapshots /tmp/screens
```

Use `scripts/swiftw` in place of `swift` to build, test and run. It makes the build work on a Mac that has only the Command Line Tools.

`pnpm ios:build` and `pnpm ios:test` build and test the iPhone app in a simulator. On a Mac without Xcode or XcodeGen they say why they are skipping and stop, so `pnpm check` still passes.

## Rules that never bend

- **Everything stays on the device.** No cloud, no analytics, no sign-up. The only network calls go to the AI server the user set.
- **The API key lives only in the Keychain.** Never in a file, a log, an error message or a test. A saved key belongs to one server and is never sent to another.
- **Nothing starts listening behind the user's back.** A link that would start or stop a recording is followed only with a ticket from our own tool or keyboard, or after the user says yes.
- **Original work only.** Do not copy code, images, icons, sounds, names or wording from any other product.
- **No third-party Swift libraries** unless there is a strong reason. Apple's frameworks cover what we need.

## Style

- Swift 6. Two-space indent, lines up to 110 characters. `pnpm format` does it for you, and `pnpm lint` must pass.
- CI builds with Xcode 26.6 (Swift 6.3), which can be older than the Swift on your Mac. If something builds for you and fails on CI, that is the first thing to check.
- Screens use SwiftUI. Colours, fonts and spacing come from `WisperUI`; do not type them into a screen.
- Text that people read is plain English: short sentences, everyday words.
- Support light and dark mode, and give every control a VoiceOver label.
- Tests use Swift Testing (`import Testing`), not XCTest.

[AGENTS.md](AGENTS.md) has the full list. It is written for AI coding agents, and it is a good read for people too.

## How the code is shaped

We like **deep modules**: a part that does a lot of work behind a small set of functions. The less a caller has to know, the better.

```
packages/domain   the shared types and the contracts between parts
packages/store    saving to files and to the Keychain
packages/ai       talking to OpenAI
packages/audio    recording the microphone and system audio
packages/engine   the dictation and meeting logic
packages/ui       shared colours, fonts and screens
packages/agent    the `wisper` tool and the MCP server
apps/macos        the macOS app
apps/ios          the iPhone app, its keyboard and its Lock Screen notice
apps/ios/Phone    most of the iPhone app's code, as a package that also builds on a Mac
```

A few things to know:

- The contracts between parts are Swift protocols in `packages/domain/Sources/WisperDomain/Seams.swift`. Each one has a real version (for example, one that calls OpenAI) and an in-memory version for tests, in `Fakes.swift`.
- `DictationEngine` and `MeetingEngine` each run a whole job, from recording to saved text, behind a few methods.
- Screens talk to one object, `AppModel`. A screen never calls OpenAI or reads a file itself.
- `domain` depends on nothing. The other packages depend on `domain`. Only the apps connect the real parts together.
- Two docs must match the code. If you change what is saved to disk, update [docs/data-format.md](docs/data-format.md). If you change a `wisper` tool, paste the output of `wisper tools --markdown` into the tables in [docs/agents.md](docs/agents.md); a test fails when they differ.

## Adding a feature

1. **Find where it belongs.** Most features are new behaviour inside an engine, plus a screen that shows it. Try to make an existing module do more before you add a new one.
2. **Keep the surface small.** Add as few public functions as you can. Callers should not need to know how it works inside.
3. **Need to reach the outside world** (network, files, microphone, another app)? Go through one of the existing contracts. Add a new contract only if you will write two versions of it: the real one and the in-memory one.
4. **Take what you need as arguments.** Do not create your own network client or file store inside a module. Return results rather than changing things out of sight.
5. **Test through the front door.** Build the engine with the in-memory versions and call its public methods. If a test has to reach inside a module, the module has the wrong shape.
6. **Add the screen last**, using `AppModel` and the `WisperUI` pieces.
7. **Ask the deletion question** about each new type: if you deleted it, would the code get simpler (it was only passing things along) or would its work spread into every caller (it earns its place)?

## Sending your change

- There is one main branch, `main`, and no staging or dev branch. Make a branch from `main` and open a pull request back into `main`.
- One feature per pull request, with everything that feature needs. A fix is its own pull request, named for the thing it fixes.
- Say in plain words what changed and how you checked it. Add a screenshot for anything you can see.
- CI must be green. It runs `pnpm check`, builds both apps, and runs the iPhone app's tests in a simulator. It runs on `macos-26` with Xcode 26.6.

### Trying the iOS build without Xcode

If you have push access and no Xcode, this builds the files you have right now on CI, without making a commit:

```bash
scripts/ci-try my-change
gh run list --branch ci/try-my-change --limit 1
```

Delete the branch when you are done: `git push origin --delete ci/try-my-change`.

CI can also take pictures of the iPhone app in a simulator. That takes about eight minutes, so it happens only when asked: start the CI workflow by hand (Actions > CI > Run workflow), or use a name that starts with `ios`, such as `scripts/ci-try ios-my-change`. The pictures are the `ios-screenshots` download of that run.

## Licence

Open Wisper is under the [MIT licence](LICENSE). By sending a change you agree that it is your own work and that it can be shared under that licence.
