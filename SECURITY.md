# Security

Open Wisper handles your voice, your text and your OpenAI API key, so we take security reports seriously.

## How to report a problem

**Please do not open a public issue for a security problem.** A public report can put other people at risk before a fix is ready.

Report it privately instead:

1. Go to the [Security tab](https://github.com/arjunkambj/open-wisper/security) of this repository.
2. Click **Report a vulnerability**.
3. Tell us what you found, how to make it happen, and what an attacker could do with it.

If you cannot see that button, open a normal issue that says only "I would like to report a security problem", with no details. A maintainer will reply with a private way to reach them.

Leave real secrets out of your report. If you need to show an API key, use a made-up one.

## What to expect

This is a small volunteer project, so we cannot promise fixed times. We will try to:

- reply within a week,
- tell you whether we can confirm the problem,
- fix confirmed problems as soon as we can, and credit you in the release notes if you would like that.

## Which versions get fixes

Only the newest release and the `main` branch. The project is young and there are no long-lived older versions.

## How Open Wisper protects your data

Knowing the design helps you judge what counts as a problem.

### Your API key

- **It lives only in the system Keychain**, on this device. It is not synced to iCloud. It is never written to a file, a log, an error message or a test.
- **It belongs to one server.** The key is saved together with the name of the server it is for, and it is sent only to that server. If the server address in your settings changes, by your hand or anyone else's, the key is not sent to the new address.
- **A wrong server address is an error.** A custom address must start with `http://` or `https://` and name a server. If it does not, nothing is sent anywhere. Open Wisper never quietly sends your audio to OpenAI instead.

### Your data

- **Everything else stays on your device** as plain files in the app's data folder. The folder and its files can be opened by your user account only. They are not encrypted by Open Wisper. Anything that runs as you can read them, the same as your documents.
- **Your audio and text go only** to OpenAI, or to the compatible server you chose, to be turned into text and notes. There is no Open Wisper server, no account, no analytics and no tracking.
- **The Mac app makes one other kind of request:** about once a day it asks GitHub whether there is a newer version, and it downloads that version when you say yes. The request carries the app's name and version. It carries none of your data and nothing about your Mac. "Updates" below has the details.
- **On a Mac, text is typed by pasting.** Open Wisper borrows the clipboard for a moment and then puts back what you had there. The text it places is marked so that clipboard-history apps know to skip it.
- **On an iPhone, your text goes to the clipboard.** That copy stays on the phone (it is not handed to your other Apple devices) and iOS clears it after 10 minutes.

### Links

Open Wisper answers links that start with `openwisper://`. Any web page, document or app can open such a link, so a link alone is never enough to make the app listen.

- A link that only shows something (the main window, a meeting) is always followed.
- The `wisper` tool, and the Open Wisper keyboard on iPhone, leave a **ticket** in the data folder before they send a link: a long random name that works once, for one minute. Only a program that can already write your Open Wisper data can leave one. A link with a valid ticket is followed at once.
- A link with no ticket that asks to **record a meeting** makes the app ask you first. There is one question at a time, and after a "no" it does not ask again for a minute.
- A link with no ticket that asks to **start dictation** or **stop a recording** is not followed. (On iPhone, a dictation link shows the Dictate screen and waits for you to tap.)
- On a Mac, a meeting that a link started always plays the start sound, also when sounds are switched off.
- No link is followed before first-run setup is finished.

### The agent tool

The `wisper` command-line tool, which is also the MCP server, runs on your own Mac and works with the same local files.

- It **can** read your meetings, notes, dictation history, dictionary and snippets, change a meeting's title, notes, tags and action items, delete a meeting, add and remove dictionary words and snippets, and ask the app to start or stop a meeting recording.
- It **cannot** read your API key (it never opens the Keychain), change your settings or your server address, start dictation, type into another app, run a command, or use the network.
- **Saving a meeting to a file is narrow on purpose.** It only makes a new Markdown (`.md`) file in a folder that already exists. It never replaces a file, never writes a hidden file or into a hidden folder, and refuses the file names that AI tools read as instructions, such as `AGENTS.md`.
- A meeting holds what other people said, and someone can say a sentence meant to trick an AI. The limits above hold even when an agent is tricked. Still, an agent you connect can read your meetings, so only connect agents you trust.

The "Safety" part of [docs/agents.md](docs/agents.md) has the full list.

### Downloads and updates

**The Mac app is signed with a certificate the project made itself, not with an Apple developer certificate, and it is not notarized.** Here is what that does and does not mean.

- **What the certificate does.** Every release is signed with the same certificate. That is how macOS knows a new version is the same app as the old one, so the permissions you gave (Microphone, Accessibility, System Audio Recording) carry over an update.
- **What it does not prove.** Anyone can make a certificate with this name. It is not checked by Apple and says nothing about who built the app, and Apple has not scanned the app for malware. That is why macOS asks you to allow the app the first time you open it. The first download is only as safe as the place you got it from: use the Releases page of this repository, compare the SHA-256 printed in the release notes, or build the app from this source code.
- **How an update is checked.** The project holds a second key, used only for updates. Each release's disk image is signed with it, and so is the small file that lists the newest version. The public half of that key is inside the app you already have. Before the app opens a download it checks the signature against that key, and it refuses a download or a list that does not match. Someone who took over the download page, or who sits between you and GitHub, cannot make your app install something else, because they do not have the key.
- **What an update cannot do.** It cannot be older than the version you have. It is never installed without your yes.
- **Where the keys are.** On the maintainer's Mac and in GitHub's encrypted secrets for this repository, which only the release workflow can read. They are never in the source code. Someone who stole both keys could publish an update that installed apps would accept. That would be a serious problem, and we want to hear about anything that could lead to it.
- **One thing that is weaker than with an Apple certificate.** macOS can make an app refuse to load code that comes from another developer. A certificate with no Apple team behind it cannot use that check, so it is off, and the app loads its one outside library, the updater, from inside its own bundle only. A program that already runs as you could still change the app on disk, as it could change your documents. The app cannot defend against that (see "Not security problems").

An app you built yourself, with your own certificate or none, does not look for updates at all.

## What we would like to hear about

- The API key ending up anywhere other than the Keychain or the server it was saved for.
- Audio or text being sent to any place other than the server you set.
- A web page, a document or a link making Open Wisper start dictation, record a meeting without asking you, or stop a recording.
- The agent tool reading the API key, changing settings, replacing a file, or writing a file it should have refused.
- The app installing an update that was not signed with the project's update key, or an older version than the one it had.
- A signing key showing up anywhere it should not be: in the source code, in a build log, or in a release.
- Another user account on the same Mac being able to read your Open Wisper data.

## Not security problems

- How OpenAI or another AI provider stores what you send it. That is covered by their own terms.
- Someone who already has full access to your unlocked Mac or iPhone reading your files.
- A program that already runs as you, with access to your files, leaving a ticket and starting a recording. Such a program can already read your data.
