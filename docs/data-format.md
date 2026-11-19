# Where Open Wisper keeps your data

Open Wisper keeps everything on your device, in one folder of plain files. There is no
database and no server. You can open the files, back them up, or change them with your own
tools.

The one thing that is **not** in this folder is your OpenAI API key. That lives in the
system Keychain and is never written to a file.

## Where the folder is

| Platform | Folder |
| --- | --- |
| macOS | `~/Library/Application Support/Open Wisper` |
| iOS | `Application Support/Open Wisper`, inside the app's own storage |

To use a different folder, set the `OPEN_WISPER_HOME` environment variable before starting
the app or the `wisper` tool:

```bash
OPEN_WISPER_HOME=~/wisper-test wisper …
```

A leading `~` is expanded. The folder is created the first time something is saved. Both
the app and the tool must be given the same value to see the same data.

## What is in it

```
<folder>/
  settings.json                    your settings
  dictionary.json                  words to spell your way
  snippets.json                    voice shortcuts
  dictations.json                  dictation history
  dictation-audio/                 audio kept for dictations
  meetings/<ID>/meeting.json       one meeting
  meetings/<ID>/notes.md           the same meeting as Markdown, for reading
  meetings/<ID>/audio/             the meeting's audio
  .lock                            empty; used to take turns (see below)
```

Files and folders are readable by your user account only.

All JSON files are:

- UTF-8, pretty-printed, with keys in alphabetical order.
- Dates are ISO 8601 in UTC, such as `2026-11-17T09:30:12Z`. A fraction of a second is
  written only when there is one (`2026-11-17T09:30:12.482Z`). When reading, any fraction
  and any time zone offset (`+05:30`) are accepted.
- IDs are UUIDs.
- A key with no value is left out instead of being written as `null`.
- A missing key gets its default, so files from older versions keep working.
- The order of entries in a list does not matter. The app sorts by date when it reads.

The examples below were written by the app itself, from made-up data.

### settings.json

```json
{
  "historyRetention" : "month",
  "keepDictationAudio" : true,
  "language" : "en",
  "launchAtLogin" : false,
  "meetings" : {
    "autoSummarize" : true,
    "captureSystemAudio" : true,
    "keepAudio" : true
  },
  "onboardedAt" : "2026-11-02T08:15:00Z",
  "playSounds" : true,
  "shortcuts" : {
    "commandMode" : {
      "modifiers" : [
        "function",
        "control"
      ]
    },
    "handsFree" : {
      "keyCode" : 49,
      "modifiers" : [
        "function"
      ]
    },
    "pasteLast" : {
      "keyCode" : 9,
      "modifiers" : [
        "command",
        "control"
      ]
    },
    "pushToTalk" : {
      "modifiers" : [
        "function"
      ]
    },
    "toggleMeeting" : {
      "keyCode" : 46,
      "modifiers" : [
        "option",
        "control"
      ]
    }
  },
  "showPill" : true,
  "smartFormatting" : true,
  "styles" : {
    "email" : "formal",
    "other" : "formal",
    "personalMessages" : "casual",
    "workMessages" : "casual"
  },
  "textModel" : "gpt-6-luna",
  "transcriptionModel" : "gpt-transcribe",
  "userName" : "Alex"
}
```

- `historyRetention` is one of `forever`, `month`, `week`, `day`, `never`. It is applied
  each time a dictation is saved: older entries, and their audio, are removed.
- `styles` values are `formal`, `casual` or `veryCasual`.
- `keyCode` is a macOS key number. A shortcut with no `keyCode` is modifier keys only.
  The order inside `modifiers` does not matter.
- Other keys you may see: `apiBaseURL` (a different OpenAI-compatible server) and
  `microphoneID`.

### dictionary.json

```json
[
  {
    "createdAt" : "2026-11-10T14:05:00Z",
    "id" : "00000000-0000-4000-8000-000000000001",
    "replaces" : "cooper netties",
    "text" : "Kubernetes"
  },
  {
    "createdAt" : "2026-11-12T09:00:00Z",
    "id" : "00000000-0000-4000-8000-000000000002",
    "text" : "Priya Raman"
  }
]
```

`text` is the right spelling. `replaces` is optional: a misheard form to swap for it.
The other keys are required.

### snippets.json

```json
[
  {
    "createdAt" : "2026-11-11T16:40:00Z",
    "expansion" : "https://cal.example.com/alex",
    "id" : "00000000-0000-4000-8000-000000000003",
    "trigger" : "my calendar link"
  }
]
```

All four keys are required.

### dictations.json

```json
[
  {
    "appName" : "Mail",
    "audioFile" : "00000000-0000-4000-8000-000000000004.m4a",
    "bundleID" : "com.apple.mail",
    "createdAt" : "2026-11-17T09:30:12.482Z",
    "duration" : 4.2,
    "id" : "00000000-0000-4000-8000-000000000004",
    "mode" : "dictation",
    "rawText" : "um could we move the review to thursday at three",
    "text" : "Could we move the review to Thursday at 3 pm?"
  },
  {
    "appName" : "Notes",
    "audioFile" : "00000000-0000-4000-8000-000000000005.m4a",
    "createdAt" : "2026-11-17T10:02:45Z",
    "duration" : 2.5,
    "failure" : "Could not reach OpenAI. Check your internet connection. (The request timed out.)",
    "id" : "00000000-0000-4000-8000-000000000005",
    "mode" : "command",
    "rawText" : "",
    "text" : ""
  }
]
```

- `rawText` is what was heard. `text` is what was typed after clean-up.
- `mode` is `dictation` or `command`. `duration` is in seconds.
- `audioFile` is the name of a file in `dictation-audio/`. It is a plain file name, never a
  path. When an entry is removed from this list, the app deletes its audio file too.
- `failure` is present only when the dictation did not work. The audio is kept for a retry.
- `appName`, `bundleID`, `audioFile` and `failure` are optional. The other keys are required.

### meetings/&lt;ID&gt;/meeting.json

```json
{
  "endedAt" : "2026-11-16T15:31:00Z",
  "id" : "00000000-0000-4000-8000-000000000006",
  "notes" : {
    "actionItems" : [
      {
        "done" : false,
        "id" : "00000000-0000-4000-8000-000000000009",
        "owner" : "Alex",
        "text" : "Check in with Sam about the billing migration"
      },
      {
        "done" : true,
        "id" : "00000000-0000-4000-8000-000000000010",
        "owner" : "Jordan",
        "text" : "Send onboarding copy to design"
      }
    ],
    "decisions" : [
      "Keep the launch date"
    ],
    "keyPoints" : [
      "Launch stays on the 14th",
      "Billing migration is the main risk"
    ],
    "summary" : "The launch is on track for the 14th. Billing migration is the one open risk."
  },
  "segments" : [
    {
      "end" : 9,
      "id" : "00000000-0000-4000-8000-000000000007",
      "speaker" : "me",
      "start" : 2,
      "text" : "Let's start with the launch date."
    },
    {
      "end" : 21.5,
      "id" : "00000000-0000-4000-8000-000000000008",
      "speaker" : "others",
      "start" : 10,
      "text" : "We're on track for the 14th. The only open risk is the billing migration."
    }
  ],
  "startedAt" : "2026-11-16T15:00:00Z",
  "status" : "ready",
  "tags" : [
    "product"
  ],
  "title" : "Weekly product sync",
  "userNotes" : "Follow up on the pricing page next week."
}
```

- The folder name is the meeting's ID. If the `id` inside the file says something else, the
  folder name wins.
- `status` is `recording`, `processing`, `ready` or `failed`. A failed meeting also has a
  `failure` key that says why.
- `segments` is the transcript. `start` and `end` are seconds from the start of the
  recording. `speaker` is `me` (your microphone), `others` (the computer's sound), or a name.
- `notes` holds the AI notes. It is missing until they have been written.
- `userNotes` is your own free-form Markdown.
- Only `id` and `startedAt` are required.

### meetings/&lt;ID&gt;/notes.md

The same meeting as a Markdown page, so that people and agents can read it without parsing
JSON. Times are shown in the device's time zone.

```markdown
# Weekly product sync

**Date:** 2026-11-16 15:00  
**Length:** 31 min  
**Tags:** product

## Summary

The launch is on track for the 14th. Billing migration is the one open risk.

## Key points

- Launch stays on the 14th
- Billing migration is the main risk

## Decisions

- Keep the launch date

## Action items

- [ ] Check in with Sam about the billing migration (Alex)
- [x] Send onboarding copy to design (Jordan)

## My notes

Follow up on the pricing page next week.

## Transcript

[00:02] Me: Let's start with the launch date.
[00:10] Others: We're on track for the 14th. The only open risk is the billing migration.
```

`notes.md` is for reading only. It is written again from `meeting.json` every time the
meeting is saved, so anything you type into it is lost. To add your own notes, change
`userNotes` in `meeting.json`.

## Rules for tools that change these files

The app and the `wisper` tool can both be running, and both write to this folder. The
simplest safe way to change data is to go through the `wisper` tool. If you write the files
yourself, follow these rules so that nobody's change is lost.

1. **Take the lock.** Open `<folder>/.lock` (create it if it is missing) and take an
   exclusive `flock` on it. Keep it only for the few milliseconds your change takes.
2. **Read again after you have the lock.** Somebody may have written since you last looked.
   Make your change to what is on disk now, not to a copy you read earlier.
3. **Replace the file in one step.** Write the new content to a temporary file in the same
   folder, with a name that starts with `.tmp-`, then rename it over the real file. Never
   write into the real file directly: a reader could see half of it.
4. **Let go of the lock.**

For example, in a shell script on macOS. `lockf` comes with macOS and takes the same lock
the app uses; `-k` tells it to leave the `.lock` file in place afterwards.

```bash
cd "${OPEN_WISPER_HOME:-$HOME/Library/Application Support/Open Wisper}"
lockf -k .lock sh -c '
  jq ".userName = \"Sam\"" settings.json > .tmp-settings.json-$$ &&
  mv .tmp-settings.json-$$ settings.json
'
```

Reading needs no lock, because every file is replaced in one step.

Other things to know:

- **The app notices your change by itself.** There is nothing to restart or reload. On
  macOS it shows up in well under a second. On iOS it can take about two seconds.
- **To add a meeting**, make the folder `meetings/<new UUID>/` and put `meeting.json` in
  it. The app writes `notes.md` for you. To delete a meeting, delete its folder.
- **Leave the audio folders to the app.** Do not rename or edit files in `dictation-audio/`
  or in a meeting's `audio/` folder. Reading them is fine.
- **Keys the app does not know are not kept.** The next time the app saves that file, they
  are gone. Keep your own data in your own files.
- **A file that cannot be read is moved aside, not deleted.** If a file is damaged, the app
  renames it to `<name>.corrupt-<time>` (for example
  `settings.json.corrupt-20261117T093012Z`) and carries on. Entries that could still be read
  are kept; the rest start from defaults. You can open the renamed file to get anything
  else back, and delete it when you are done.
- Hidden files that start with `.tmp-` or `.trash-` are work in progress. Leave them alone.
  Leftovers from a crash are cleaned up by the app.
