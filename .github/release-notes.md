## Download

**{{ZIP}}** (below, under Assets) holds `Open Wisper.app` for macOS 14.4 or newer.

1. Unzip it and move `Open Wisper.app` into your Applications folder.
2. Open it. The first time, macOS will stop it, because this build is **not signed with an Apple developer certificate and not notarized** (it has only an ad hoc signature).
3. To allow it: open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Open Wisper. You only do this once.

If you would rather not run an unsigned app, build it yourself: `pnpm install && pnpm mac`. The README has the details.

To check your download, run `shasum -a 256 {{ZIP}}`. It should print:

```
{{SHA256}}
```

You need your own OpenAI API key. Open Wisper has no account and no server of its own.

There is no iOS download. To use the iOS app, build it with Xcode (see the README).
