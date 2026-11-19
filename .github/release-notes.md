## Download

**{{ZIP}}** (below, under Assets) holds `Open Wisper.app` for macOS 14.4 or newer.

1. Unzip it and move `Open Wisper.app` into your Applications folder.
2. Open it. The first time, macOS will stop it, because this build is **not signed with an Apple developer certificate and not notarized** (it has only an ad hoc signature).
3. To allow it: open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Open Wisper. You only do this once.

**Updating from an older version?** Because the build has no certificate, macOS treats each new version as a new app. The permissions you gave before (Microphone, Accessibility, System Audio Recording) can look on but do nothing. If dictation or the shortcuts stop working after an update, open **System Settings → Privacy & Security**, remove Open Wisper from each list, and allow it again.

If you would rather not run an unsigned app, build it yourself: `pnpm install && pnpm mac`. The README has the details.

To check your download, run `shasum -a 256 {{ZIP}}`. The line it prints should start with:

```
{{SHA256}}
```

To connect an AI agent, see [docs/agents.md](https://github.com/arjunkambj/open-wisper/blob/main/docs/agents.md). The `wisper` tool is inside the app, at `Open Wisper.app/Contents/MacOS/wisper`.

You need your own OpenAI API key. Open Wisper has no account and no server of its own.

There is no iOS download. To use the iOS app, build it with Xcode (see the README).
