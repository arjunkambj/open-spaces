# Open Wisper

[![CI](https://github.com/arjunkambj/open-wisper/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/arjunkambj/open-wisper/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Open Wisper is a free, open-source app for macOS and iOS that turns your voice into text. Hold a key, speak, and clean text appears in whatever app you are typing in; it can also record your meetings and write the notes.

<!-- screenshots -->

> **Status: early.** This is a first version. Some things will be rough or broken. The macOS app is the main focus. The iOS app is newer and less tested. There is no signed download yet, so for now you build it yourself. Bug reports are welcome.

Open Wisper is an independent open-source project. It is not affiliated with Wispr Flow.

## What it does

**Dictation**

- **Dictate anywhere.** Hold a key, talk, let go. The text is typed into the app you are using.
- **Hands-free mode.** Press once to start, press again to stop. Good for long thoughts.
- **Command mode.** Select some text, hold a key, and say how to change it ("make this shorter").
- **Personal dictionary.** Teach it names and words it keeps getting wrong.
- **Snippets.** Say a short phrase ("my calendar link") and get a longer piece of text.
- **Writing style per kind of app.** Formal in email, casual in chat. You choose.
- **History with stats.** See what you dictated, search it, and see your word count, speed and streak.

**Meetings**

- **Record a meeting.** It records your microphone and what your Mac plays, so both sides of a call are captured.
- **Transcript with speakers.** Lines are marked "Me" or "Others".
- **AI notes.** A summary, key points, decisions and action items, written when the meeting ends.
- **Ask about a meeting.** Ask a question and get an answer from that meeting's transcript.
- **Markdown export.** Take your notes anywhere.

**Everything else**

- **Works with your AI agent.** A command-line tool and an MCP server let an agent such as Claude read your meetings and notes and add to them. (MCP is a common way for AI agents to use outside tools.)
- **iOS app with a keyboard.** Dictate on your phone, in any app.
- **Use your own server.** Point it at any server that speaks the same language as OpenAI's, such as a proxy or a model running on your own machine.

## How it works

1. You speak. Open Wisper records the audio on your device.
2. The audio goes to OpenAI, using **your own API key**. OpenAI sends back the words.
3. A second, quick request tidies the text: it removes "um" and "uh", fixes punctuation, and applies your writing style. You can turn this off.
4. The text is typed into your app.

That is the only thing that leaves your device, and it goes only to OpenAI (or the server you chose instead).

- **No account.** There is nothing to sign up for.
- **No server of ours.** We do not run one. We never see your audio, your text or your key.
- **No tracking.** No analytics and no usage reports.
- **Your data stays with you.** History, meetings, dictionary and settings are plain files on your device. Your API key is kept in the system Keychain, the place your Mac and iPhone keep passwords.

What you send to OpenAI is covered by OpenAI's own data rules, and you pay OpenAI for what you use.

## What you need

- A Mac with **macOS 14.4 or newer**.
- An **OpenAI API key** (or a compatible server). You can make a key at [platform.openai.com](https://platform.openai.com/api-keys).
- To build it:
  - Apple's **Command Line Tools** (`xcode-select --install`) or Xcode, with Swift 6 or newer.
  - **Node.js 22 or newer** and **pnpm 12**. These only run the build commands. The app itself is all Swift.
- For the iOS app as well: full **Xcode**, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), and an iPhone or simulator with **iOS 17 or newer**.

## Build and run

### macOS

The Command Line Tools are enough. You do not need Xcode.

```bash
git clone https://github.com/arjunkambj/open-wisper.git
cd open-wisper
pnpm install
pnpm mac
```

`pnpm mac` builds the app, wraps it into `Open Wisper.app`, and opens it. The first build takes a few minutes. The app then asks for your name, your API key and a few permissions.

### iOS

The iOS app needs full Xcode.

```bash
pnpm install
pnpm ios:generate
```

This makes an Xcode project inside `apps/ios`. Open it in Xcode, choose your own team under **Signing & Capabilities** for each target, and run it on your iPhone or a simulator. To use the keyboard, add it in **Settings → General → Keyboard → Keyboards** on your phone.

## Permissions on first run

macOS asks before an app can listen or type for you. Open Wisper asks for three things and tells you why.

| Permission | Why it is needed | Needed for |
| --- | --- | --- |
| **Microphone** | To hear you. | Dictation and meetings |
| **Accessibility** | To type the text into the app you are using, to read the text you selected for command mode, and to notice your shortcut keys while you are in another app. | Dictation |
| **System Audio Recording** | To record what your Mac plays, which is how the other people on a call get into the transcript. | Meetings only |

You can change any of these later in **System Settings → Privacy & Security**. If you do not want your Mac's sound recorded, turn that off in Open Wisper's settings; meetings then record only your microphone.

## Shortcuts

These are the defaults on macOS. You can change every one of them in Settings.

| Action | Keys | What it does |
| --- | --- | --- |
| Push to talk | Hold `fn` | Hold to dictate. Release to insert the text. |
| Hands-free mode | `fn` + `Space` | Press once to start dictating. Press again to stop. |
| Command mode | Hold `fn` + `⌃ Control` | Select text, hold, and say how to change it. |
| Paste last transcript | `⌃ Control` + `⌘ Command` + `V` | Insert your most recent dictation again. |
| Start or stop meeting recording | `⌃ Control` + `⌥ Option` + `M` | Record a meeting from anywhere. |

## Connect an agent

Open Wisper comes with a command-line tool called `wisper` and an MCP server. With them, an AI agent can look through your meetings and dictations, read notes, and write notes back. Changes an agent makes show up in the app right away.

See [docs/agents.md](docs/agents.md) for how to set it up and what it can do.

## Where your data lives

On macOS, everything is in one folder:

```
~/Library/Application Support/Open Wisper
```

The files are JSON, Markdown and audio. You can read them, back them up, or delete them yourself. Your API key is not in that folder; it is in the Keychain.

See [docs/data-format.md](docs/data-format.md) for what each file holds.

## Project layout

```
apps/macos        the macOS app
apps/ios          the iOS app and its keyboard
packages/domain   the shared types and the contracts between parts
packages/store    saving to files and to the Keychain
packages/ai       talking to OpenAI
packages/audio    recording the microphone and system audio
packages/engine   the dictation and meeting logic
packages/ui       shared colours, fonts and screens
packages/agent    the `wisper` tool and the MCP server
docs              guides
scripts           build and CI scripts
```

All of it is Swift, with no third-party Swift libraries. [Turborepo](https://turborepo.dev) and pnpm run each part's build, tests and style check in the right order.

Useful commands:

```bash
pnpm check     # style check, build and tests for everything
pnpm test      # tests only
pnpm format    # fix the code style in place
pnpm mac       # build and open the macOS app
```

## Roadmap

Ideas, not promises:

- A signed download, so you do not have to build it yourself.
- Transcription that runs fully on your device, with no API key.
- A more complete iOS app.
- More languages for the app's own text.

Have an idea? [Open an issue](https://github.com/arjunkambj/open-wisper/issues/new/choose).

## Contributing

Help is welcome: bug reports, ideas, fixes and features. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. It is short. If you work with an AI coding agent, point it at [AGENTS.md](AGENTS.md).

Found a security problem? Please report it privately. See [SECURITY.md](SECURITY.md).

## Licence

[MIT](LICENSE). Use it, change it, share it.
