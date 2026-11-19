# Open Wisper for iPhone

The iPhone app and its keyboard. Tap one big button, speak, and the text is on your
clipboard. It also records meetings and writes the notes. Everything stays on the phone;
the only thing that leaves is audio and text sent to OpenAI with your own key.

## What is in this folder

```
project.yml   the Xcode project, as text. XcodeGen turns it into OpenWisper.xcodeproj
              and Generated/ (the targets' Info.plist files). Neither is kept in git
App/          the app target: entry point, Shortcuts actions, icon, launch screen
Keyboard/     the keyboard extension target: one small class
Widgets/      the widget extension target: the Lock Screen notice for a recording
Shared/       code compiled into both the app and the widget extension: the Stop button's action
Tests/        checks that run inside the built app (its Info.plist, its keyboard)
Phone/        a Swift package with nearly all of the code:
                WisperPhone     the Dictate and Library screens, the tabs, links, wiring
                WisperKeyboard  everything the keyboard does
                WisperLive      the notice a recording puts on the Lock Screen
scripts/      screenshots: pictures of the app from a simulator
```

Most of the code is in `Phone/` on purpose. A Swift package builds on any Mac, even one
without Xcode, so its tests run in seconds and its screens can be drawn to image files.
The Xcode targets only start things up.

## Run it

You need a Mac with Xcode 26 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
pnpm install                      # once, in the repo root
pnpm ios:generate                 # makes apps/ios/OpenWisper.xcodeproj
open apps/ios/OpenWisper.xcodeproj
```

Pick an iPhone simulator and press Run. In a simulator there is nothing more to set up.
Run `pnpm ios:generate` again whenever `project.yml` changes or files are added.

From the command line:

```bash
pnpm ios:build                    # build for a simulator, without signing
pnpm ios:test                     # run the tests on a simulator
```

On a Mac without Xcode these two say why they are skipping and stop. CI builds the app on
every pull request.

### Try it without a key or a microphone

Start the app with `--demo` and it runs on made-up data kept in memory. Nothing is recorded,
sent or saved. Add `--scene <name>` to open in one state: `dictate-recording`,
`dictate-result`, `dictate-failed`, `meetings`, `meeting`, `keyboard`, `first-run` and more (the list
is `DemoScene` in `Phone/Sources/WisperPhone/DemoScene.swift`). In Xcode, add these under
Product > Scheme > Edit Scheme > Arguments.

## Put it on your own iPhone

Signing is not set up in the project, because it is yours to choose.

1. In Xcode, select the **OpenWisper** project, then each of the targets **OpenWisper**,
   **OpenWisperKeyboard** and **OpenWisperWidgets**. Under Signing & Capabilities, pick
   your team.
2. Change the bundle IDs. `dev.openwisper.ios` belongs to this project, so Apple will not
   let another team use it. In `project.yml`, change the `PRODUCT_BUNDLE_IDENTIFIER` lines
   of the three targets you just signed (`dev.openwisper.ios`, `dev.openwisper.ios.keyboard`
   and `dev.openwisper.ios.widgets`) to something of your own, such as
   `com.yourname.wisper`, `com.yourname.wisper.keyboard` and `com.yourname.wisper.widgets`.
   The two extensions' IDs must start with the app's ID. The fourth line, for
   **OpenWisperTests**, can stay as it is.
3. Change the App Group, in three places that must match:
   - `App/OpenWisper.entitlements`
   - `Keyboard/OpenWisperKeyboard.entitlements`
   - `groupID` in `Phone/Sources/WisperKeyboard/SharedFolder.swift`

   Use a name of your own that starts with `group.`, such as `group.com.yourname.wisper`.
4. Run `pnpm ios:generate` and build to your phone.

These changes are for your own copy. Keep them out of a pull request. Three checks in
`Tests/BundleTests.swift` name the project's own bundle IDs, so `pnpm ios:test` fails on
them in a copy with changed IDs.

### Why the App Group matters

The app and the keyboard are two separate programs. iOS lets them share exactly one folder,
called an App Group, and only when both are signed with it. Open Wisper keeps its library
there so the keyboard can read your latest dictation and your snippets.

If the App Group is missing or the names do not match, the app still works: it keeps its
library in its own folder. The keyboard then cannot see it and says so instead of typing
anything. When you fix the signing later, the app moves the library into the shared folder
the next time it starts, so nothing is lost.

Your OpenAI key is never shared. It stays in the app's own Keychain. The keyboard does not
need it and cannot read it.

## What works on the phone

- **Dictate.** Tap the button and speak, tap again to finish. Or hold the button and talk,
  then let go. The text is copied to the clipboard at once and shown with Copy, Share and
  Edit. The screen stays awake while you record. Switching to another app or locking the
  phone finishes the dictation.
  The copy stays on this iPhone (it is not handed to your Mac or iPad) and iOS clears it
  after 10 minutes, because dictated text can be private. The text itself stays in the app:
  tap Copy to put it back.
- **Meetings.** Record, get a transcript and notes. Recording carries on when the screen
  locks or you switch apps. While it runs, the Lock Screen and the Dynamic Island show the
  meeting's name, a clock and a Stop button.
- **History, Dictionary, Snippets, Style, Settings.** The same screens as on the Mac.
- **Shortcuts and Siri.** Four actions: Start Dictation, Start Meeting Recording, Stop
  Meeting Recording, Copy Last Dictation. They show up in the Shortcuts app by themselves,
  so you can put one on the Action button, the Lock Screen or the Home Screen.
- **Links.** `openwisper://meetings/<id>` opens a meeting. Links that would turn the
  microphone on are not obeyed blindly, because any app or web page can open a link:
  - `openwisper://meetings/start?title=Standup` asks you first. Say no and it stays quiet
    for a minute.
  - `openwisper://dictation/toggle` only shows the Dictate screen. You tap the button.
  - `openwisper://meetings/stop` does nothing.

  The Open Wisper keyboard is the exception. Its Dictate key adds a one-time ticket to the
  link (a small file in the shared folder, good for one minute), so the app knows the
  request is its own and starts listening at once. Shortcuts actions and the Stop button
  on the Lock Screen do not use links at all.

## What the phone cannot do

These are limits of iOS, not things left unfinished.

- **It cannot type into other apps.** On a Mac, Open Wisper puts the text where your cursor
  is. An iPhone app is not allowed to. So the text goes to the clipboard, and you paste it,
  or tap **Insert latest** on the Open Wisper keyboard.
- **A meeting records only your microphone.** iOS does not let an app record the sound of
  other apps, so the other side of a call is picked up only as far as your microphone
  hears it. Put the phone on the table, or the call on speaker.
- **The microphone can only be started while the app is on screen.** That is why the
  Shortcuts actions that record open the app first.

## The keyboard, and its limits

iOS does not let a keyboard use the microphone. So the Open Wisper keyboard does not listen
itself. It is a small companion:

- **Dictate** opens the app, already listening. Speak, then go back to where you were
  (the back arrow in the top left corner). Leaving the app finishes the dictation, so
  there is no need to tap the button first. If the app opens but is not listening (the
  keyboard could not leave its ticket), tap the button yourself.
- **Insert latest** types your most recent dictation.
- Your **snippets** sit in a row, one tap each.
- Space, delete (hold to keep deleting), return, and the globe key to switch keyboards.

It is not a keyboard for typing letters. Switch to it when you want to dictate or paste,
and back to your normal keyboard with the globe key.

To turn it on: Settings > General > Keyboard > Keyboards > Add New Keyboard > Open Wisper,
then tap it in the list and turn on **Allow Full Access**. The app walks you through this
in its first-run setup and under Library > Keyboard.

**Allow Full Access** is needed for two things: opening the app from the Dictate key, and
reading the shared library. The keyboard has no code that uses the network and does not
record what you type. Without Full Access it explains what to turn on and does nothing else.

If your history is set to "Don't keep history", there is no latest dictation for the
keyboard to find. Paste from the clipboard instead.

## For contributors

```bash
cd apps/ios/Phone
../../../scripts/swiftw build     # builds on a Mac, no Xcode needed
../../../scripts/swiftw test      # the tests, on fakes
../../../scripts/swiftw run wisper-phone-snapshots /tmp/phone   # draws the screens to PNG files
```

`wisper-phone-snapshots` draws the phone's own screens and the keyboard on a phone-sized
canvas, in light and dark, without a simulator. Look at the pictures after every change to
a screen. `scripts/screenshots` (in this folder) does the same with the real app in a
simulator; run `pnpm ios:build` first. CI takes those pictures only when asked, because
they take about eight minutes: start the CI workflow by hand (Actions > CI > Run
workflow), or run `scripts/ci-try ios` from the repo root. They are the `ios-screenshots`
download of that run.

An App Intent that a widget shows as a button (the Stop button on the Lock Screen) must be
compiled into the app and the widget extension both. Such files go in `Shared/`.

Code that needs UIKit sits behind `#if canImport(UIKit)` or `#if os(iOS)` and is compiled
only by Xcode. Keep those parts small, because only CI checks them.

The keyboard runs with very little memory. `WisperKeyboard` must not depend on the audio or
AI packages, and must not call `UIApplication.shared`.
