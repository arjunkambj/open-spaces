## Download

**{{DMG}}** (below, under Assets) holds Spaces for a Mac with Apple silicon and macOS 14.4 or newer.

**Already have Spaces?** You do not need this page. The app offers the update by itself, or choose **Check for Updates…** from its menu. Your permissions and settings stay as they are.

**New here?**

1. Open the file you downloaded and drag **Spaces** onto **Applications**.
2. Open it from Applications. The first time, macOS stops it and says it could not check the app, because this build is **not signed with an Apple developer certificate and not notarized**. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to the line about Spaces. The button is there for about an hour after step 2.
4. macOS asks once more. Confirm, and type your Mac password. You only do this once.

If you would rather not run an app Apple has not checked, build it yourself: `pnpm install && pnpm mac`. The README has the details.

To check your download, run `shasum -a 256 {{DMG}}`. The line it prints should start with:

```
{{SHA256}}
```

`appcast.xml`, also under Assets, is the file installed apps read to find this version. You do not need to download it.

To connect an AI agent, see [docs/agents.md](https://github.com/arjunkambj/open-spaces/blob/main/docs/agents.md). The `spaces` tool is inside the app, at `Spaces.app/Contents/MacOS/spaces`.

You need your own OpenAI API key. Spaces has no account and no server of its own.

