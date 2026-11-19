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

- **Your API key lives only in the system Keychain.** It is never written to a file, a log, an error message or a test. It is sent only to the AI server you set, as part of each request.
- **Everything else stays on your device** as plain files in the app's data folder. They are not encrypted by Open Wisper. Anyone who can read your user account's files can read them, the same as your documents.
- **The only network calls** go to OpenAI, or to the compatible server you chose. Your audio and text are sent there to be turned into text and notes. There is no Open Wisper server, no account, no analytics and no tracking.
- **The agent tools** (the `wisper` command-line tool and the MCP server) run on your own machine and work with the same local files. An agent you connect can read your meetings and dictation history, so only connect agents you trust.
- **Downloads are not signed with an Apple developer certificate yet.** Until they are, the safest way to get the app is to build it from this source code.

Things we would like to hear about include: the API key ending up anywhere other than the Keychain or the server you set, data being sent to any other place, another app or website being able to read your data or start a recording through Open Wisper, and files being written outside the data folder.

## Not security problems

- How OpenAI or another AI provider stores what you send it. That is covered by their own terms.
- Someone who already has full access to your unlocked Mac or iPhone reading your files.
