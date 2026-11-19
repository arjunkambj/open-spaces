# Connect an AI agent to Open Wisper

Open Wisper comes with a small program called `wisper`. It lets an AI agent, or you in a terminal, work
with your meetings, notes and dictations. Claude Code, Claude Desktop, Cursor, Codex and any other tool
that speaks MCP can use it.

MCP (Model Context Protocol) is a common way for AI tools to plug into other programs. You tell your AI
tool where `wisper` is, and it can then use everything listed on this page.

## What an agent can do

- **Read meetings.** List them, read the summary, key points, decisions and action items, and read the
  transcript (all of it, or one part by time or by speaker).
- **Search.** Find where something was said or noted, across every meeting. It gets back short matching
  lines with the time they were said, not whole meetings.
- **Work with action items.** List what is still open across all meetings, add items, tick them off,
  change them, remove them.
- **Add to a meeting.** Add notes, change the title, set tags.
- **Export.** Get a meeting as one Markdown document, or save it to a file.
- **Record.** Start and stop a meeting recording in the running app, and check whether one is running.
- **Dictation history.** Read and search what you dictated.
- **Dictionary and snippets.** Teach Open Wisper how to spell a name, and add or remove voice snippets.
- **Read a few settings.** Your name, language and model choices. Never the API key.

## Where the program is

`wisper` ships inside the app:

```
/Applications/Open Wisper.app/Contents/MacOS/wisper
```

If you keep the app somewhere else, use that path instead. This command prints the right settings for your
copy, with the full path filled in:

```bash
"/Applications/Open Wisper.app/Contents/MacOS/wisper" mcp-config
```

```json
{
  "mcpServers": {
    "open-wisper": {
      "command": "/Applications/Open Wisper.app/Contents/MacOS/wisper",
      "args": [
        "mcp"
      ]
    }
  }
}
```

To type `wisper` instead of the full path in a terminal, link it once:

```bash
sudo ln -s "/Applications/Open Wisper.app/Contents/MacOS/wisper" /usr/local/bin/wisper
```

The rest of this page writes `wisper` for short.

## Set up your AI tool

### Claude Code

Run this once in a terminal:

```bash
claude mcp add --scope user open-wisper -- "/Applications/Open Wisper.app/Contents/MacOS/wisper" mcp
```

`--scope user` makes it available in every project. Leave it out to add it to the current project only.
Everything after `--` is the command Claude Code runs to start the tool.

Check that it connected with `claude mcp get open-wisper`, or type `/mcp` inside Claude Code.

### Claude Desktop

1. Open **Settings**, choose **Developer**, and click **Edit Config**. This opens the file
   `~/Library/Application Support/Claude/claude_desktop_config.json`.
2. Paste the JSON from `wisper mcp-config`. If the file already has an `mcpServers` section, add the
   `open-wisper` entry inside it.
3. Quit Claude Desktop and open it again.

### Cursor

Put the same JSON in `~/.cursor/mcp.json` (for every project) or in `.cursor/mcp.json` inside one project.
Cursor's guide also lists a `type` field for programs it starts itself, so add it:

```json
{
  "mcpServers": {
    "open-wisper": {
      "type": "stdio",
      "command": "/Applications/Open Wisper.app/Contents/MacOS/wisper",
      "args": ["mcp"]
    }
  }
}
```

### Codex

```bash
codex mcp add open-wisper -- "/Applications/Open Wisper.app/Contents/MacOS/wisper" mcp
```

Or add this to `~/.codex/config.toml`:

```toml
[mcp_servers.open-wisper]
command = "/Applications/Open Wisper.app/Contents/MacOS/wisper"
args = ["mcp"]
```

### Any other MCP client

Tell it to start a local (stdio) server with:

- command: `/Applications/Open Wisper.app/Contents/MacOS/wisper`
- arguments: `mcp`

Most clients read the JSON that `wisper mcp-config` prints.

### No MCP? Use the commands

An agent that can run shell commands does not need MCP at all. Tell it to run `wisper --help`. That one
screen lists every command, and each command explains itself with `--help`. Add `--json` to any command to
get JSON instead of text.

## Things to ask

- "Summarise my last meeting."
- "What are my open action items? Group them by meeting."
- "What did we decide about pricing in the Northwind call?"
- "Find where someone mentioned the billing migration, and tell me what was said just before it."
- "Tick off the action item about the onboarding copy."
- "Add a note to today's standup: Sam confirmed the migration is done."
- "Draft a follow-up email for my last meeting and save the notes to my Desktop as Markdown."
- "Start recording a meeting called Design review." Later: "Stop the recording."
- "Add Kubernetes to my dictionary. It keeps getting written as cooper netties."

## Commands for the terminal

```bash
wisper --help                                  # everything, on one screen
wisper meetings list --since 7d                # meetings from the last 7 days
wisper meetings get latest                     # notes and action items of the newest meeting
wisper meetings show 3F2A9C1E                  # the same, for one meeting by the start of its ID
wisper meetings transcript latest --from 10:00 --to 15:00
wisper meetings search "pricing"               # short matching lines, with times
wisper meetings add-note latest "Sam confirmed the migration is done."
wisper meetings update latest --title "Pricing review" --add-tags pricing,q4
wisper meetings export latest --path ~/Desktop # saves a Markdown file
wisper actions list --open --owner Alex        # what is still to do
wisper actions add latest "Send the proposal" --owner Alex
wisper actions done 7B1D4F02                   # tick one off (reopen undoes it)
wisper recording start --title "Design review"
wisper recording status
wisper recording stop
wisper dictations search "flat white"
wisper dictionary add "Kubernetes" --replaces "cooper netties"
wisper snippets add "my calendar link" "https://cal.example.com/alex"
wisper settings get
wisper doctor                                  # is everything in place?
```

A few rules hold everywhere:

- **Meetings** can be named by their full ID, by the first 4 or more characters of the ID, or as `latest`.
  Action items are named by their ID or the start of it. Lists show the IDs.
- **Dates** can be written as `2026-11-18`, as `2026-11-18T09:30:00+05:30`, as `today` or `yesterday`, or
  as an age: `36h`, `7d`, `2w`. Dates in the output always carry your own time zone.
- **Times in a recording** are seconds (`90`) or minutes and seconds (`1:30`).
- **`--json`** turns the output of any command into JSON.
- **Exit codes:** `0` means done. `1` means it could not be done (not found, or the app did not answer).
  `2` means the command was written wrong. Errors are printed to standard error.

## All tools

These tables are printed by `wisper tools --markdown`, so they always match the program. Each tool has two
names: the one an MCP client sees, and the command for the terminal. Both do exactly the same thing.
`wisper <command> --help` explains every argument.

The last column says what a tool does to your data. MCP clients are told the same, so a careful client can
ask you before it runs a tool that overwrites or deletes.

<!-- tools:start -->
### Meetings

| MCP tool | Command | What it does | Effect |
| --- | --- | --- | --- |
| `meetings_list` | `wisper meetings list [--limit N] [--since SINCE] [--until UNTIL] [--status recording\|processing\|ready\|failed] [--tag TAG]` | List meetings, newest first. | Reads |
| `meetings_get` | `wisper meetings get <meeting> [--include-transcript]` | Show one meeting: its notes, action items and details. | Reads |
| `meetings_transcript` | `wisper meetings transcript <meeting> [--from FROM] [--to TO] [--speaker SPEAKER] [--offset N] [--limit N]` | Read what was said in a meeting, all of it or one part. | Reads |
| `meetings_search` | `wisper meetings search <query> [--limit N] [--per-meeting N] [--since SINCE]` | Find where something was said or noted, across all meetings. | Reads |
| `meetings_add_note` | `wisper meetings add-note <meeting> <text>` | Add text to the end of a meeting's notes. | Adds |
| `meetings_update` | `wisper meetings update <meeting> [--title TITLE] [--notes NOTES] [--tags A,B] [--add-tags A,B] [--remove-tags A,B]` | Change a meeting's title, notes or tags. | Overwrites or deletes |
| `meetings_export` | `wisper meetings export <meeting> [--path PATH] [--no-include-transcript]` | Get a meeting as one Markdown document, or save it to a file. | Adds |
| `meetings_delete` | `wisper meetings delete <meeting>` | Delete a meeting, its transcript, notes and audio for good. | Overwrites or deletes |

### Action items

| MCP tool | Command | What it does | Effect |
| --- | --- | --- | --- |
| `actions_list` | `wisper actions list [--status open\|done\|all] [--owner OWNER] [--meeting MEETING] [--limit N]` | List action items from all meetings. | Reads |
| `actions_add` | `wisper actions add <meeting> <text> [--owner OWNER]` | Add an action item to a meeting. | Adds |
| `actions_set_done` | `wisper actions set-done <action> [--no-done]` | Mark an action item as done, or as open again. | Adds or changes |
| `actions_update` | `wisper actions update <action> [--text TEXT] [--owner OWNER]` | Change the text or the owner of an action item. | Overwrites or deletes |
| `actions_remove` | `wisper actions remove <action>` | Remove an action item for good. | Overwrites or deletes |

### Recording

| MCP tool | Command | What it does | Effect |
| --- | --- | --- | --- |
| `recording_status` | `wisper recording status` | Say whether a meeting is being recorded right now. | Reads |
| `recording_start` | `wisper recording start [--title TITLE]` | Ask the Open Wisper app to start recording a meeting. | Adds or changes |
| `recording_stop` | `wisper recording stop` | Ask the Open Wisper app to stop the recording. | Adds or changes |

### Dictation history

| MCP tool | Command | What it does | Effect |
| --- | --- | --- | --- |
| `dictations_list` | `wisper dictations list [query] [--limit N] [--since SINCE] [--app APP]` | List recent dictations, or search them. | Reads |

### Dictionary

| MCP tool | Command | What it does | Effect |
| --- | --- | --- | --- |
| `dictionary_list` | `wisper dictionary list` | List the words Open Wisper has been taught to spell. | Reads |
| `dictionary_add` | `wisper dictionary add <text> [--replaces REPLACES]` | Teach Open Wisper how to spell a name or a term. | Adds or changes |
| `dictionary_remove` | `wisper dictionary remove <word>` | Remove a word from the dictionary. | Overwrites or deletes |

### Snippets

| MCP tool | Command | What it does | Effect |
| --- | --- | --- | --- |
| `snippets_list` | `wisper snippets list` | List voice snippets: what the user says and what gets typed. | Reads |
| `snippets_add` | `wisper snippets add <trigger> <expansion>` | Add a voice snippet. | Adds |
| `snippets_remove` | `wisper snippets remove <snippet>` | Remove a voice snippet. | Overwrites or deletes |

### Settings

| MCP tool | Command | What it does | Effect |
| --- | --- | --- | --- |
| `settings_get` | `wisper settings get` | Show the user's name, language and model choices. | Reads |
<!-- tools:end -->

Some commands can be written in more than one way: `meetings show` is `meetings get`, `actions done` and
`actions reopen` are `actions set-done`, `actions edit` is `actions update`, and `dictations search` is
`dictations list`.

Four commands are only for the terminal: `wisper mcp` (what your AI tool runs), `wisper mcp-config`,
`wisper tools` and `wisper doctor`.

## More for MCP clients

**Meetings as documents.** Every meeting is also offered as a Markdown document (an MCP "resource") at
`openwisper://meetings/<id>`. In clients that let you attach resources to a chat, you can pick a meeting from
the list. `openwisper://meetings/latest` is always the newest one. Clients that ask for change notices are
told when a meeting is added or changed.

**Ready-made requests.** Three prompts show up in clients that have a prompt menu:

| Prompt | What it does |
| --- | --- |
| `summarise_meeting` | Summarises a meeting: outcome, decisions, action items. Uses the newest meeting unless you name one. |
| `open_action_items` | Goes through your open action items and says what to do first. |
| `follow_up_email` | Drafts a short follow-up email for a meeting. |

**Protocol versions.** `wisper mcp` speaks the current MCP revision (`2026-07-28`) and the older ones that
start with a handshake (`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`). It reads one JSON message
per line from standard input and writes one per line to standard output. Logs go to standard error.

## Recording, and the app's links

`wisper` does not record anything itself. To start or stop a recording it asks the running app, using
links the app answers to. You can use the same links from Shortcuts, Raycast, a script, or `open` in a
terminal:

| Link | What the app does |
| --- | --- |
| `openwisper://meetings/start` | Starts recording a meeting |
| `openwisper://meetings/start?title=Standup` | Starts recording with a title |
| `openwisper://meetings/stop` | Stops the recording |
| `openwisper://meetings/<id>` | Shows that meeting |
| `openwisper://dictation/toggle` | Starts or stops dictation |
| `openwisper://hub` | Shows the main window |

```bash
open -g "openwisper://meetings/start?title=Standup"
```

After asking, `wisper recording start` waits a few seconds until the new meeting shows up, then returns its
ID. If the app does not answer, it says so and tells you what to check. After `wisper recording stop` the
app writes the transcript and notes. That can take a minute. Until then the meeting's status is
`processing`; when it is `ready` the notes are there.

While a meeting is being recorded or its notes are being written, `wisper` will read it but not change it.

## Privacy

- **Everything stays on your Mac.** `wisper` reads and writes the same folder as the app:
  `~/Library/Application Support/Open Wisper`. It makes no network calls at all. There is no account and no
  tracking.
- **It cannot read your API key.** The key is kept in the macOS Keychain. `wisper` has no code that opens the
  Keychain, so no agent can get the key through it. It also never shows the address of a custom server,
  because an address can hold a password.
- **Your AI tool is a separate matter.** What an agent reads through `wisper` (a transcript, for example)
  goes to that agent's AI provider, like anything else you show it. Connect only tools you trust with your
  meetings.
- **Changes are real.** An agent can change notes and tags, and delete meetings. Tools that overwrite or
  delete are marked, so your AI tool can ask you first. `meetings delete` needs the meeting's ID, never
  `latest`, and cannot be undone.
- **Recording.** An agent can start a recording when you ask it to. Tell the people in the meeting, as you
  would when you press the button yourself.

## If something does not work

Run `wisper doctor`. It shows where the data folder is, how much is in it, whether a meeting is being
recorded and whether the app seems to be running.

- **The AI tool does not show Open Wisper.** Check the path in its settings, then restart the tool. Running
  `wisper mcp-config` again prints the correct path.
- **"There are no meetings yet."** `wisper` is looking at an empty folder. If you moved your data with the
  `OPEN_WISPER_HOME` setting, the AI tool has to be given the same setting. `wisper mcp-config` adds it for you
  when it is set.
- **Recording does not start.** The app has to be open. It may also be waiting for you to allow the
  microphone, or to enter an API key.
