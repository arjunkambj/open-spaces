# Where Spaces keeps your data

Spaces keeps everything on your device, in one folder of plain files. There is no
database and no server. You can open the files, back them up, or change them with your own
tools.

Your API keys (OpenAI, and Anthropic if you use Claude) are kept apart from everything else, in
one file, `api-key.json`.
Only your user account can open it, and the key is never written to any other file. That
file is in this folder.

## Where the folder is

```
~/Library/Application Support/Spaces
```

To use a different folder, set the `SPACES_HOME` environment variable before starting
the app or the `spaces` tool:

```bash
SPACES_HOME=~/spaces-test spaces …
```

A leading `~` is expanded. The folder is created the first time something is saved. Both
the app and the tool must be given the same value to see the same data.

## What is in it

```
<folder>/
  settings.json                    your settings
  api-key.json                     your API keys (macOS only, see below)
  dictionary.json                  words to spell your way
  snippets.json                    voice shortcuts
  tasks.json                       daily tasks and their categories
  dictations.json                  dictation history
  dictation-audio/<ID>.m4a         audio kept for one dictation
  meetings/<ID>/meeting.json       one meeting
  meetings/<ID>/notes.md           the same meeting as Markdown, for reading
  meetings/<ID>/audio/             the meeting's audio (see below)
  agents/<pid>.json                an AI tool connected through `spaces mcp` (see below)
  .lock                            empty; used to take turns (see below)
  .tickets/                        short-lived proof of where a link came from (see below)
```

Files and folders are readable by your user account only.

Nothing is made until it is needed, so a new install has only some of these.

All JSON files are:

- UTF-8, pretty-printed, with keys in alphabetical order.
- Dates are ISO 8601 in UTC, such as `2026-11-17T09:30:12Z`. A fraction of a second is
  written only when there is one (`2026-11-17T09:30:12.482Z`). When reading, any fraction
  and any time zone offset (`+05:30`) are accepted, and so is a date with no time
  (`2026-11-17`).
- IDs are UUIDs.
- A key with no value is left out instead of being written as `null`.
- A missing key gets its default, unless the notes below say the key is required.
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
    "keepAudio" : true,
    "offerCalendarMeetings" : false
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
  "transcriptionModel" : "gpt-live-transcribe",
  "userName" : "Alex"
}
```

- `historyRetention` is one of `forever` (what a new install uses), `month` (30 days),
  `week`, `day`, `never`. It is applied each time a dictation is saved: older entries, and
  their audio, are removed. With `never`, nothing about a dictation is kept.
- `styles` values are `formal`, `casual` or `veryCasual`.
- `modifiers` values are `function`, `control`, `option`, `shift` and `command`. `keyCode`
  is a macOS key number. A shortcut with no `keyCode` is modifier keys only. The order
  inside `modifiers` does not matter.
- `meetings.offerCalendarMeetings` (Mac only, off unless you turn it on): when a call on
  your calendar starts, the app offers to record it, and a meeting recorded during a call
  takes the event's title and the names of the people invited. The calendar is read on the
  Mac itself; nothing from it is sent anywhere.
- `language` is a two-letter code such as `en`. It is left out when the language is to be
  worked out from the audio.
- Other keys you may see: `microphoneID`, and `apiBaseURL`, the address of a different
  OpenAI-compatible server. That address must start with `http://` or `https://`. If it is
  set to anything else, the app shows an error and sends nothing; it does not fall back to
  OpenAI. The saved API key is tied to the server it was saved for, so changing this
  address by hand does not send your key to the new server.
- A value the app does not know (a style it has no name for, say) makes the file count as
  damaged: it is moved aside, and that setting goes back to its default (see "A file that
  cannot be read" below).

### api-key.json

```json
{"keys": {"api.openai.com": "sk-...", "api.anthropic.com": "sk-ant-..."}}
```

- `keys` holds one key per server, under the host it was saved for. Each key is sent to its
  own server only. If the server address in `settings.json` names another host, no key is
  sent there until you save one for it.
- `api.anthropic.com` is the Anthropic key, used only when `textModel` is a Claude model.
- The file is readable by your user account only (mode 0600) and is left out of backups.
  Removing the last key in Settings deletes the file.
- If you copy, zip or share the data folder, leave this file out.
- Tools must not read, copy or change this file. The `spaces` tool never opens it.

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

### tasks.json

```json
{
  "categories" : [
    "General",
    "Gooseworks"
  ],
  "tasks" : [
    {
      "addedBy" : "agent",
      "category" : "Gooseworks",
      "createdAt" : "2026-11-24T06:26:08.699Z",
      "day" : "2026-11-25",
      "id" : "00000000-0000-4000-8000-000000000004",
      "status" : "staged",
      "text" : "Send the proposal"
    }
  ]
}
```

`categories` lists the category names in the order the app shows them. New tasks go into the first one
unless another is named. With no file, or no `categories` key, the list is `General` and `Gooseworks`.
Names are matched without regard to case, and each is used once.

Each task:

- `text`: one line, at most 500 characters.
- `day`: the day the task is for, written `yyyy-MM-dd`, with no time or time zone. A task stays on its
  day wherever the Mac is.
- `category`: one of `categories`.
- `status`: `staged` (an AI tool suggested it and it waits for your OK in the Tasks tab), `open` or
  `done`.
- `addedBy`: `me` (added in the app) or `agent` (added through `spaces`).

All the keys of a task are required.

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
    "text" : "Could we move the review to Thursday at 3 pm?",
    "timing" : {
      "captureMs" : 140,
      "cleanUpMs" : 780,
      "insertMs" : 9,
      "path" : "file",
      "totalMs" : 1920,
      "transcribeMs" : 950
    }
  },
  {
    "appName" : "Notes",
    "audioFile" : "00000000-0000-4000-8000-000000000005.m4a",
    "createdAt" : "2026-11-17T10:02:45Z",
    "duration" : 2.5,
    "failure" : "OpenAI did not answer in time, even on a second try. Try again in a moment.",
    "id" : "00000000-0000-4000-8000-000000000005",
    "mode" : "command",
    "rawText" : "",
    "text" : ""
  }
]
```

- `rawText` is what was heard. `text` is what was typed after clean-up.
- `mode` is `dictation` or `command`. `duration` is in seconds.
- `appName` and `bundleID` say which app the text went into, when that is known.
- `audioFile` is the name of a file in `dictation-audio/`. It is a plain file name, never a
  path. When an entry is removed from this list, the app deletes its audio file too. A
  dictation that worked keeps its audio only while "Keep audio of dictations" is on.
- `failure` is present only when the dictation did not work. It holds the message shown to
  you. `text` is then empty, and the audio is kept for a retry whatever the audio setting.
- **The "not finished" entry.** An entry is written as soon as you stop speaking, before
  the text is made. Its `failure` reads "Spaces closed before this dictation was
  finished. Try it again." and its `rawText` and `text` are empty. When the text is ready,
  the finished entry takes its place, with the same `id`. The app does not show the entry
  while it is working. If the app closes in between, the entry stays and you can retry it
  from Home.
- `selection` is present only on a command that failed or was not finished. It is the text
  that was selected, kept so a retry changes the same text. An empty string means nothing
  was selected.
- `timing` says how long each step took, in thousandths of a second, counted from the moment
  you let go of the key. It holds numbers only, never anything that was said. It is there to
  find out where the waiting goes.
  - `path`: `file` when the finished recording was uploaded, `live` when the sound was sent
    while you were still speaking.
  - `captureMs`: from letting go of the key to a finished audio file. Left out on a retry.
  - `transcribeMs`: sending the audio and waiting for the words. On a failed entry, how long
    it took to fail.
  - `cleanUpMs`: the language model's tidying (or its answer to a command). Left out when it
    was not asked: smart formatting is off, or the text was only a word or two.
  - `insertMs`: putting the text into the app. Left out when nothing was inserted.
  - `totalMs`: from letting go of the key (or from starting a retry) until the text was typed.
    A little more than the steps added up: reading settings and saving the entry sit between.

  Every key in `timing` is optional, and so is `timing` itself: the "not finished" entry has
  none.
- `id`, `createdAt`, `mode`, `rawText`, `text` and `duration` are required. The other keys
  are optional. An entry that lacks a required key, or holds a value the app cannot read,
  counts as damaged: the file is moved aside and saved again without that entry (see "A file
  that cannot be read" below).

### meetings/&lt;ID&gt;/meeting.json

```json
{
  "attendees" : [
    "Jordan Lee",
    "Priya Raman"
  ],
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
- The folder name must be a UUID. Folders with any other name are left alone.
- `status` is `recording`, `processing`, `ready` or `failed`. It is `ready` when left out.
- `failure` says what went wrong. A `failed` meeting has one. A `ready` meeting can have
  one too, when only a part is missing: a piece that could not be turned into text, notes
  that could not be written, or audio that was lost in a crash.
- `segments` is the transcript. `start` and `end` are seconds from the start of the
  recording. `speaker` is `me` (your microphone) or one of the people on the computer's
  sound: `Speaker 1`, `Speaker 2` and so on for voices told apart that have no name yet, or
  a name. A name comes from you, from an agent, or from the AI notes when the talk makes it
  plain ("thanks, Priya"). `others` stands for everyone on the computer's sound when their
  voices were not told apart: in meetings recorded through a server of your own, and in
  meetings from before voices were told apart.
- To rename a speaker, change `speaker` on every one of their segments, and `owner` on every
  action item that names them. Never use `me` or `others` as a name.
- `notes` holds the AI notes. It is missing until they have been written.
- `userNotes` is your own free-form Markdown.
- `attendees` holds the names of the other people invited to the calendar event the meeting
  was recorded during (an email address when the calendar has no name). It is empty when
  there was no such event, and an empty list when left out.
- `endedAt` is missing while the meeting is being recorded.
- At the top level, only `id` and `startedAt` are required. A meeting with no `title` is
  shown as "Untitled meeting".
- Inside, the lists are stricter. When `notes` is there it needs all four of its keys. A
  segment needs all five of its keys. An action item needs `id`, `text` and `done`;
  `owner` is optional. If one of these is missing, the file counts as damaged: it is moved
  aside and the meeting is saved again without that whole part, all of `notes` or all of
  `segments` (see "A file that cannot be read" below).

### meetings/&lt;ID&gt;/audio/

The app owns this folder. It holds the recording in pieces of about 30 seconds, one set per
track: `microphone-0000.m4a`, `system-0000.m4a`, and so on. (`system` is the sound the Mac
plays.)

While a piece is being recorded there is also a plain `.wav` copy beside it
(`microphone-0003.wav`). An `.m4a` file cannot be read until it is closed, so the copy is
what saves the sound if the app closes suddenly. When the piece is finished, the copy is
removed.

`manifest.json` is the app's own record of the pieces. This example was shortened by hand:

```json
{
  "chunks" : [
    {
      "duration" : 30,
      "file" : "microphone-0000.m4a",
      "offset" : 0,
      "segments" : [
        {
          "end" : 9,
          "id" : "00000000-0000-4000-8000-000000000007",
          "speaker" : "me",
          "start" : 2,
          "text" : "Let's start with the launch date."
        }
      ],
      "state" : "done",
      "track" : "microphone"
    }
  ],
  "voices" : [
    {
      "end" : 14.25,
      "file" : "system-0000.m4a",
      "name" : "Speaker 1",
      "start" : 4.25
    }
  ]
}
```

- `offset` and `duration` are in seconds. `offset` counts from the start of the meeting.
- `state` is `pending` (not turned into text yet), `done` or `failed` (waiting for a retry).
- `segments` holds what was heard in that piece, in the same shape as in `meeting.json`. A
  segment here keeps the speaker the app first gave it (`Speaker 1`); a new name lives in
  `meeting.json` and is carried over whenever the app writes the transcript again.
- `lostAudio` is `true` when some sound could not be saved. It is left out otherwise.
- `voices` lists the voices told apart on the `system` track, at most four, each with a
  stretch of 2 to 10 seconds (`start` to `end`, in seconds from the start of `file`) in which
  only that voice speaks. Each later `system` piece is sent to OpenAI with these stretches, so
  the same person keeps the same number from piece to piece. It is left out until the first
  voice is found. Voices are only told apart when speech goes to OpenAI itself.

**After a crash.** The audio files are the truth, and the manifest is only a record of
them. The next time the app starts, it finishes every meeting that was left as `recording`
or `processing` from the audio in this folder. Audio files the manifest does not list are
added to it, so a manifest that is missing or out of date hides nothing. For the piece
that was being written when the app closed, the `.wav` copy is used in place of the
`.m4a`, and stays in the folder under its `.wav` name. If there is no copy, that last part
is gone and the meeting says so.

**When the folder goes away.** With "Keep audio after transcribing" turned off, the app
deletes this folder once every piece has been turned into text and nothing is left to
retry. Audio that has not been turned into text is never deleted. Deleting the meeting
deletes its audio.

### meetings/&lt;ID&gt;/notes.md

The same meeting as a Markdown page, so that people and agents can read it without parsing
JSON. Times are shown in the device's time zone.

```markdown
# Weekly product sync

**Date:** 2026-11-16 15:00  
**Length:** 31 min  
**Tags:** product  
**Attendees:** Jordan Lee, Priya Raman

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
`userNotes` in `meeting.json`. A section with nothing in it is left out.

### agents/&lt;pid&gt;.json

Each `spaces mcp` server (the program your AI tool starts) writes one file here, named after
its process number, so the app can show which AI tool is connected. It holds who the tool says
it is and when it was last used. It never holds anything the tool read or wrote.

```json
{
  "client" : {
    "name" : "claude-code",
    "version" : "2.1.0"
  },
  "endedAt" : "2026-11-17T11:02:41Z",
  "lastActiveAt" : "2026-11-17T11:02:40Z",
  "lastTool" : "meetings_search",
  "pid" : 4242,
  "startedAt" : "2026-11-17T09:15:03Z"
}
```

- `client` is how the tool names itself over MCP: `name`, and `title` and `version` when it gives
  them. The tool is not checked, so this is for showing only. `name` is empty when it gave none.
- The file is written when the first request arrives, and again when the tool names itself
  differently.
- `lastActiveAt` moves on when the tool calls a tool, reads a meeting document or uses a
  ready-made request. To spare the disk, it is written at most about every 30 seconds.
  `lastTool` is the name of the tool it called last.
- `endedAt` is written when the server stops on its own, at the end of its input. While it is
  missing the server is running. If the process with that number is gone (the server was
  stopped without warning), readers treat the file as ended at `lastActiveAt`.
- Files that ended more than a day ago are deleted by the app when it reads the folder.

There is nothing here for you to change.

### .tickets/

The app answers links that start with `openspaces://`. Any web page or document can open
such a link, so a link that would start or stop a recording has to prove where it came
from. Before the `spaces` tool sends one, it puts an empty file
with a long random name in this folder and adds that name to the link. The app checks for
the file and deletes it. A ticket works once, and only for one minute. Old tickets are
cleaned up by themselves.

There is nothing here for you to read or change. Do not make tickets for other programs: a
ticket tells the app to start listening without asking you.

## Rules for tools that change these files

The app and the `spaces` tool can both be running, and both write to this folder. The
simplest safe way to change data is to go through the `spaces` tool. If you write the files
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
cd "${SPACES_HOME:-$HOME/Library/Application Support/Spaces}"
lockf -k .lock sh -c '
  jq ".userName = \"Sam\"" settings.json > .tmp-settings.json-$$ &&
  mv .tmp-settings.json-$$ settings.json
'
```

Reading needs no lock, because every file is replaced in one step.

Other things to know:

- **The app notices your change by itself.** There is nothing to restart or reload. It
  shows up in well under a second.
- **To add a meeting**, make the folder `meetings/<new UUID>/` and put `meeting.json` in
  it. The app writes `notes.md` for you. To delete a meeting, delete its folder.
- **Leave the audio folders to the app.** Do not rename or edit files in `dictation-audio/`
  or in a meeting's `audio/` folder. Reading them is fine. A file in `dictation-audio/`
  that no entry in `dictations.json` names is deleted the next time the app starts.
- **Leave a meeting alone while it is `recording` or `processing`.** The app is still
  writing its transcript, status and notes, and will write over yours.
- **Keys the app does not know are not kept.** The next time the app saves that file, they
  are gone. Keep your own data in your own files.
- **A file that cannot be read is moved aside, not deleted.** If a file is damaged, the app
  renames it to `<name>.corrupt-<time>` (for example
  `settings.json.corrupt-20261117T093012Z`) and carries on. Entries that could still be read
  are kept; the rest start from defaults. You can open the renamed file to get anything
  else back, and delete it when you are done.
- Hidden files that start with `.tmp-` or `.trash-` are work in progress. Leave them alone.
  Leftovers from a crash are cleaned up by the app.
