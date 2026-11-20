# Contributing to Spaces

Thanks for wanting to help. This page tells you how to set up, how the code is shaped, and how to send a change.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to help

- **Report a bug** or **suggest a feature**: [open an issue](https://github.com/arjunkambj/open-spaces/issues/new/choose).
- **Fix or build something**: for anything bigger than a small fix, open an issue first so we can agree on the idea before you spend time on it.
- **Security problems** are reported privately. See [SECURITY.md](SECURITY.md).

## Set up

You need a Mac with macOS 14.4 or newer, Apple's Command Line Tools (`xcode-select --install`) or Xcode, Node.js 22 or newer, and pnpm 12.

```bash
git clone https://github.com/arjunkambj/open-spaces.git
cd open-spaces
pnpm install
pnpm mac        # build and open the macOS app
```

The first build takes a few minutes. The app lands in `apps/macos/build/Spaces.app`.

macOS ties the permissions you give (Microphone, Accessibility, System Audio Recording) to the signature of the app. Without a signing certificate every build has a different one, so after a rebuild the permissions stop working until you remove the app from each list and add it again. To stop that, run this once:

```bash
scripts/setup-signing
```

It makes a free certificate of your own, asks for nothing, and keeps it in `~/.config/open-spaces/signing`, outside the project. Every build after that is signed with it. You can build without it too; the build script then warns you.

To look at the app without touching your real data, microphone or key, start it on made-up data:

```bash
"apps/macos/build/Spaces.app/Contents/MacOS/Spaces" --demo
```

The iPhone app also needs full Xcode and XcodeGen (`brew install xcodegen`). Run `pnpm ios:generate`, then open `apps/ios/Spaces.xcodeproj` with Xcode. [apps/ios/README.md](apps/ios/README.md) has the rest. Without Xcode you can still work on everything else, and on most of the iPhone code too: it lives in a package, `apps/ios/Phone`, that builds on any Mac. Our CI builds the iPhone app itself on every pull request.

You do not need an OpenAI key to work on the code. Demo mode and the screen pictures run on made-up data.

## The one command to run before you push

```bash
pnpm check
```

It runs the style check and the build for every part. Our CI runs the same command, so if it passes for you it should pass there. Runs after the first are quick, because parts that did not change are skipped.

Other commands:

```bash
pnpm lint       # style check only
pnpm format     # fix the style in place

# Work on one part:
cd packages/engine
../../scripts/swiftw build

# Draw the screens to PNG files, without opening a window:
cd packages/ui
../../scripts/swiftw run spaces-snapshots /tmp/screens
```

Use `scripts/swiftw` in place of `swift` to build and run. It makes the build work on a Mac that has only the Command Line Tools.

`pnpm ios:build` builds the iPhone app for a simulator. On a Mac without Xcode or XcodeGen it says why it is skipping and stops, so `pnpm check` still passes.

## Rules that never bend

- **Everything stays on the device.** No cloud, no analytics, no sign-up. The only network calls go to the AI server the user set.
- **The API key lives only in its own private file** (`api-key.json`, mode 0600). Never in any other file, a log or an error message. A saved key belongs to one server and is never sent to another.
- **Nothing starts listening behind the user's back.** A link that would start or stop a recording is followed only with a ticket from our own tool or keyboard, or after the user says yes.
- **Original work only.** Do not copy code, images, icons, sounds, names or wording from any other product.
- **No tests, no legacy, no fallbacks.** We keep no test suites. We keep no code for old callers or old data: change the callers instead. We write no second path in case the first one fails: fail plainly, with a clear message.
- **No third-party Swift libraries** unless there is a strong reason. Apple's frameworks cover what we need. There is one, in the Mac app: [Sparkle](https://sparkle-project.org), which updates the app. An updater replaces the app itself, so it is safer to use the one most Mac apps share than to write our own.
- **A signing key never goes into the project.** Not into a file or a log. `scripts/setup-signing` keeps the keys in your home folder and in GitHub's encrypted secrets.

## Style

- Swift 6. Two-space indent, lines up to 110 characters. `pnpm format` does it for you, and `pnpm lint` must pass.
- CI builds with Xcode 26.6 (Swift 6.3), which can be older than the Swift on your Mac. If something builds for you and fails on CI, that is the first thing to check.
- Screens use SwiftUI. Colours, fonts and spacing come from `SpacesUI`; do not type them into a screen.
- Text that people read is plain English: short sentences, everyday words.
- Support light and dark mode, and give every control a VoiceOver label.

[AGENTS.md](AGENTS.md) has the full list. It is written for AI coding agents, and it is a good read for people too.

## How the code is shaped

We like **deep modules**: a part that does a lot of work behind a small set of functions. The less a caller has to know, the better.

```
packages/domain   the shared types and the contracts between parts
packages/store    saving to files
packages/ai       talking to OpenAI
packages/audio    recording the microphone and system audio
packages/engine   the dictation and meeting logic
packages/ui       shared colours, fonts and screens
packages/agent    the `spaces` tool and the MCP server
apps/macos        the macOS app
apps/ios          the iPhone app, its keyboard and its Lock Screen notice
apps/ios/Phone    most of the iPhone app's code, as a package that also builds on a Mac
```

A few things to know:

- The contracts between parts are Swift protocols in `packages/domain/Sources/SpacesDomain/Seams.swift`. Each one has a real version (for example, one that calls OpenAI) and an in-memory version, in `Fakes.swift`, that demo mode and the screen pictures run on.
- `DictationEngine` and `MeetingEngine` each run a whole job, from recording to saved text, behind a few methods.
- Screens talk to one object, `AppModel`. A screen never calls OpenAI or reads a file itself.
- `domain` depends on nothing. The other packages depend on `domain`. Only the apps connect the real parts together.
- Two docs must match the code. If you change what is saved to disk, update [docs/data-format.md](docs/data-format.md). If you change a `spaces` tool, paste the output of `spaces tools --markdown` into the tables in [docs/agents.md](docs/agents.md), between the two markers.

## Adding a feature

1. **Find where it belongs.** Most features are new behaviour inside an engine, plus a screen that shows it. Try to make an existing module do more before you add a new one.
2. **Keep the surface small.** Add as few public functions as you can. Callers should not need to know how it works inside.
3. **Need to reach the outside world** (network, files, microphone, another app)? Go through one of the existing contracts. Add a new contract only if you will write two versions of it: the real one and the in-memory one.
4. **Take what you need as arguments.** Do not create your own network client or file store inside a module. Return results rather than changing things out of sight.
5. **Use the front door.** Callers use a module's public methods. If one has to reach inside a module, the module has the wrong shape.
6. **Add the screen last**, using `AppModel` and the `SpacesUI` pieces.
7. **Ask the deletion question** about each new type: if you deleted it, would the code get simpler (it was only passing things along) or would its work spread into every caller (it earns its place)?

## Sending your change

- There is one main branch, `main`, and no staging or dev branch. Make a branch from `main` and open a pull request back into `main`.
- One feature per pull request, with everything that feature needs. A fix is its own pull request, named for the thing it fixes.
- Say in plain words what changed and how you checked it. Add a screenshot for anything you can see.
- CI must be green. It runs `pnpm check` and builds both apps. It runs on `macos-26` with Xcode 26.6.

### Trying the iOS build without Xcode

If you have push access and no Xcode, this builds the files you have right now on CI, without making a commit:

```bash
scripts/ci-try my-change
gh run list --branch ci/try-my-change --limit 1
```

Delete the branch when you are done: `git push origin --delete ci/try-my-change`.

CI can also take pictures of the iPhone app in a simulator. That takes about eight minutes, so it happens only when asked: start the CI workflow by hand (Actions > CI > Run workflow), or use a name that starts with `ios`, such as `scripts/ci-try ios-my-change`. The pictures are the `ios-screenshots` download of that run.

## Making a release

A release is a GitHub Release with three files: the disk image (`Spaces-<version>.dmg`), a copy of it under the fixed name `Spaces.dmg` (what the website's download button points at), and `appcast.xml`, the small file installed apps read to find out there is a new version. Publishing a release is what hands the update to everyone who has the app.

Only a maintainer with push access can do this.

1. **Raise the version** in `apps/macos/package.json` (for example `0.1.0` to `0.2.0`) and merge that into `main`.
2. **Tag that commit and push the tag:**

   ```bash
   git checkout main && git pull
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. **Wait for the Release workflow** (Actions > Release). It:
   - checks that the tag matches the version;
   - builds the app and signs it with the project's certificate;
   - makes the disk image and signs it;
   - signs the disk image with the update key and writes `appcast.xml`, with GitHub's list of what was merged as the "what is new" text;
   - checks that the new build number is higher than the one of the newest release, so installed apps will take it;
   - publishes the release with both files.

Installed apps find it within a day, or at once with **Check for Updates…**.

Good to know:

- **The build number** is what apps compare, not the version text. It is the version as one number, a dot, and the number of commits: version 0.2.0 at 57 commits is `200.57`. The top of `apps/macos/scripts/bundle` has the details. Keep the second and third numbers of a version below 100.
- **A tag with a `-` in it** (such as `v0.2.0-beta.1`, with `0.2.0` in `package.json`) becomes a pre-release. GitHub does not hand a pre-release out as the newest one, so installed apps do not see it.
- **A release cannot be taken back** from people who already installed it. To fix a bad one, publish a newer one.
- **To try the whole thing on your Mac** without publishing anything: `pnpm mac:dmg`, then `apps/macos/scripts/appcast`. The result is in `apps/macos/build/update`.

### The keys

Two keys make a release, and both were made once with `scripts/setup-signing`:

- **A code-signing certificate**, "Spaces Self-Signed". Every build is signed with it, so macOS sees each version as the same app and keeps its permissions.
- **An update signing key.** Its public half is in `apps/macos/Resources/Info.plist` (`SUPublicEDKey`). An installed app takes an update only when it was signed with the private half.

They live in `~/.config/open-spaces/signing` on the maintainer's Mac, and as three encrypted secrets of the GitHub repository (`MAC_SIGNING_P12_BASE64`, `MAC_SIGNING_P12_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`), which `scripts/setup-signing --github` saves. They are never in the project.

**Keep a backup** of `identity.p12`, `identity.p12.password` and `update-key` from that folder, somewhere safe and private. If they are lost, installed apps can no longer be updated: people would have to download the app again by hand, and allow its permissions again.

### Releases from a fork

A fork cannot use the project's keys, and must not: its users would get updates from the wrong place. To publish your own releases:

1. Run `scripts/setup-signing --github`. It makes your own two keys and saves the secrets in your fork.
2. Put the public key it prints into `apps/macos/Resources/Info.plist` as `SUPublicEDKey`, and change `SUFeedURL` there to your fork's address.

## Licence

Spaces is under the [MIT licence](LICENSE). By sending a change you agree that it is your own work and that it can be shared under that licence.
