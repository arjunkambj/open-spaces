# Speed and reliability of dictation

Written on 19 November 2026, after a morning of real use showed two problems: dictations that
failed with "the request timed out", and a wait after speaking that felt long next to the voice
input in T3 Code. This note records what T3 Code does, what we do, and what we changed.

Where a statement comes from reading code, it says so. Where it is a guess, it says that too.

## How T3 Code's voice input works

Read from the public repository `pingdotgg/t3code` (MIT licence) at commit `0317d4f4`, 19 November
2026. Nothing was run and nothing was copied: we take the approach, not the code.

**Where the text is made.** On a Mac, the main path does not use the internet at all. T3 Code runs
a small local program next to the app (it calls this "the environment"), and that program runs a
speech model on the Mac itself. The engine is `transcribe-cpp` 0.4.1, started as a separate child
process so a stuck model can be killed (`apps/server/src/speech/native.ts`,
`apps/server/src/speech/SpeechService.ts`). The models are files of 35 MB to 5 GB that the person
downloads once from a list (`apps/server/src/speech/catalog.json`): Parakeet, Whisper, Moonshine,
Canary and others. The default pick for English is "Parakeet Unified English 0.6B", about 730 MB.

**It listens while you speak.** The microphone is read in the app window as plain sound samples,
one channel, 16,000 samples a second, in pieces of half a second
(`apps/web/src/speech/pcmWorklet.ts`, `browserPcmCapture.ts`). For models marked "Live preview",
each piece is sent at once over a local connection (a WebSocket at `/ws/voice`) to the local
program, which feeds it to the model and sends back the text so far
(`packages/client-runtime/src/voice-input/stream.ts`, `apps/server/src/speech/stream.ts`). At most
two pieces are on their way at a time, so sound never piles up. When you stop, the app sends
"finish" and gets the final text. By then almost all of the work is done.

**The model stays loaded.** After a dictation the model is kept in memory for 15 minutes by
default (`UNLOAD_MILLISECONDS`, `speechModelUnloadTimeout` in `SpeechService.ts`), so the next
dictation does not pay to load it again.

**No tidy-up pass unless you ask.** "Transcript cleanup" (a second call to a language model) is
off by default. When it is on, there is a Skip button, and a failure inserts the plain transcript
(`packages/client-runtime/src/voice-input/controller.ts`, `docs/user/voice-input.md`).

**The text goes into its own box.** T3 Code types into its own message box. It does not have to
paste into another app.

**Its cloud path is no faster than ours.** T3 Code can also send audio to OpenAI
(`apps/server/src/speech/CloudSpeech.ts`). That path waits until you stop, builds one WAV file,
and uploads it to `https://api.openai.com/v1/audio/transcriptions` with the model
`gpt-transcribe`: the same call we make. It allows two minutes, does not retry, and never
streams ("a cloud recording never uses the streaming socket", `docs/internals/voice-input.md`).

**On failure** it keeps the recording so the person can press retry, and it never switches to
another destination by itself.

**What we could not verify.** We did not look at how the owner's copy of T3 Code is set up. If it
feels instant, it is almost certainly using a local model with live preview, because its OpenAI
path does the same slow thing ours did. That is an inference from the code, not a measurement.

## How Spaces worked before this change

1. Key down: the microphone opens and sound is written to one `.m4a` file.
2. Key up: wait up to 0.25 s for the last sound, close the file.
3. Build the upload, open a connection to OpenAI if none is open, upload the file, wait for the
   whole transcript.
4. Make a second call to a language model to tidy the text (up to 12 s, then the plain text is
   used).
5. Paste into the app in front.

Nothing was prepared while the person was still speaking. Every step after key up was paid for
in waiting.

## Where the time goes between "stop speaking" and "text appears"

| Step | T3 Code, local model | Spaces before | Spaces now |
| --- | --- | --- | --- |
| Finish the recording | flush half a second of sound | up to 0.25 s, plus closing the file | the same |
| Open a connection | none (same Mac) | 0.1 to 2 s when none was open (see the measurement below) | 0 in the usual case: opened at key down |
| Send the sound | already sent while speaking | whole file after key up (small: 4 KB per second of speech) | the same file, on a connection that is already open |
| Make the text | already done, only the tail is left | whole clip, after upload | whole clip, after upload |
| Tidy the text | off by default | second model call, every time | second model call, on a connection opened at key down; skipped for very short text |
| Insert | into its own box | paste, 0 to 0.4 s waiting for keys to lift | the same |

Most numbers in the "before" column are estimates from how the protocols work. One was
measured, from the owner's Mac on its VPN, with three small questions to OpenAI that carry no
key: the first took 2.4 s, of which 2.1 s was opening the connection. The next two took 0.43 s
each, with 0.04 s to open. So a connection opened fresh can cost two seconds here, and one
that is already open costs nothing. From this release the app measures every dictation (see
"What we measure" below), so the real numbers can be read from the history file.

## Why dictations timed out

The failed dictations all carried the message for "no reply byte arrived in time". Two things
made one stall cost about half a minute and then fail:

- **One wait for everything.** A short clip waited 20 s for the first byte of a reply, inside a
  total allowance of about 28 s. A 2-second clip normally answers in about a second, so 20 s of
  silence was 19 s of waiting for nothing.
- **The retry used the same connection.** The app used the system's shared connection pool. When
  a connection in that pool has quietly died (a VPN changed its keys, the Mac slept, the far side
  dropped an idle connection), a request written into it gets no answer and no error. The retry
  was written into the same dead connection, and the allowance ran out.

A probe from the owner's Mac showed OpenAI answering in 0.3 to 1.0 s on a healthy connection, so
the network at rest was fine. That points at dead connections in the pool. It is the most likely
cause, not a proven one: we could not reproduce the owner's stall on demand.

## What shipped

### Reliability: a stall no longer costs half a minute

All of this is in `packages/ai` (`Connections.swift`, `Client.swift`).

- **Our own connections.** The app no longer uses the system's shared connection pool. It keeps
  a private one: no cookies, no cache, nothing on disk, and it fails at once when there is no
  network instead of sitting on a recording.
- **A connection that may be dead is not used.** A fresh set of connections is made when the
  old ones were unused for a minute, when the Mac slept, when the network changed (Wi-Fi, cable,
  a VPN going up or down), and after any request that failed to get an answer.
- **Give up fast, then try once more on a new connection.** Two waits are now kept apart:
  - *sending*: only a standstill counts (8 s with nothing moving), so a long recording on a slow
    link is fine as long as it keeps going;
  - *answering*: once everything is sent, OpenAI gets 5 s plus 40 s per megabyte of audio.
    A megabyte is over four minutes of speech, so a dictation of a few seconds gets about 5 s.

  When the first try gets no answer, the same request goes out again at once on a new
  connection with twice the wait. After two silent tries the person is told. A request to tidy
  text waits about 4 s before its second try.

  A server of the person's own (a custom server address) is often a model running on their own
  machine: far slower, and busy with one request at a time. It gets 20 s plus 60 s per megabyte
  before anything is sent twice, and tidying keeps its full 12 s.
- **The connection is opened or checked while you speak.** The moment the key goes down, the
  app sends one tiny question to the server (no key, no audio, no text). When there is no
  connection yet, this opens one (it may take up to 8 s; nobody waits for it). When there is
  one, this checks it: 2.5 s without a sign of life and the connections are replaced, before
  the upload ever needs them. During a long recording it repeats every 20 s. An upload that
  starts while a check is running waits for its answer, so it is never written into a
  connection that is about to be found dead.
- **A plain message.** A time-out now reads "OpenAI did not answer in time, even on a second
  try. Try again in a moment." It used to blame the internet connection. The recording and its
  history entry are kept and can be retried, as before.

How one stalled request plays out for a 5-second dictation:

| | Before | Now |
| --- | --- | --- |
| Dead connection found while speaking | not looked for | replaced before key up: no delay at all |
| Connection dies between the check and the upload | 20 s wait, retry on the same dead connection, fail at about 28 s | about 5.8 s wait, then the retry on a new connection succeeds: text after about 7 s |
| The server truly does not answer | fail at about 28 s | fail at about 17 s (5.8 s, then 11.5 s on a new connection) |

Where the "now" numbers come from: the waits themselves (5.8 s, then 11.5 s) are fixed in
`OpenAITranscriber.limits`. The "before" numbers come from the old code's settings and from the
owner's history file.

Decisions, and why:

- **No retry later in the background.** The second try happens inside the request, before the
  person is told. A retry that finished a minute later would type text into whatever app is in
  front by then, so that is left to the Retry button.
- **No heartbeat while the app is idle.** Checking at key down costs nothing the person can
  feel, and an app that talks to a server every 30 seconds all day is not what people expect
  from a local-first tool.
- **HTTP/3 is not asked for.** It runs over a kind of traffic (UDP) that some VPNs drop. The
  system has no public switch to forbid it, so a stall is handled the same way whichever
  protocol was used: a new connection.

Not proven here: that this cures the stall on the owner's VPN. That needs a day of real use,
and the timing numbers below will show it.

### What we measure

Every dictation now saves how long each step took, in `timing` on its history entry
(`docs/data-format.md`): finishing the recording, upload plus transcription, tidying, inserting,
and the total from key up to inserted text. Numbers only, never text. A failed entry says how
long it took to fail.

### Latency: smaller waits in the same path

- The connection is opened at key down (see above), so the upload does not start by opening one.
  Whenever no connection was open, this saves what opening one costs: about a tenth of a second
  on a good day, and two seconds on the bad one measured above.
- The look at which app is in front now runs while the microphone closes, not after.
- Tidying no longer makes everyone wait up to 12 s. The wait is 5 s plus a little per word, up
  to the old limit: about 5.5 s for a sentence, the full 12 s only for a very long dictation.
  After that the words go in as they were heard.
- Checked and left alone:
  - The tidy-up request already asks for no "thinking" (`reasoning_effort: none`). A cap on the
    length of the answer would not make the usual case faster (the model stops when it is
    done), and some servers reject the setting, so none was added.
  - Text of one or two words is already not sent for tidying.
  - `MicrophoneSource.stop()` waits up to 0.25 s for the last piece of sound so the last word is
    not cut off. Typical cost is about a tenth of a second. It cannot be tested without a real
    microphone, so it was not touched. `timing.captureMs` now measures it.
  - The paste path (`apps/macos/Sources/SpacesMac/Text/MacTextTarget.swift`, read only) has no
    fixed sleep before the paste. It waits, in steps of 20 ms and for at most 0.4 s, for ⌃, ⌥
    and ⇧ to be let go, which matters only when one of those is the dictation key. The 1.5 s
    before the clipboard is given back happens after the paste and holds nothing up.

### What a 5 to 10 second dictation costs now, step by step

Estimates until real numbers are read from `timing`:

| Step | Before | Now |
| --- | --- | --- |
| Finish the recording | 0.1 to 0.3 s | the same |
| Open a connection | 0 to 2 s | 0 |
| Upload and transcription | about 1 to 2 s | the same |
| Tidying | about 0.5 to 1.5 s, up to 12 s | the same, but at most about 5.5 s for a sentence |
| Insert | under 0.1 s | the same |

The two big steps are still there: the whole clip is transcribed after key up, and tidying is a
second call. Removing the first needs streaming (below). Removing the second is a product
choice: turning "smart formatting" off already does it.

### Streaming while speaking (in the code, switched off until the app passes it in)

This is the part T3 Code's local path does and we did not: send the sound while the person is
still speaking, so the words are nearly ready at key up.

**What OpenAI offers** (read from its documentation on 19 November 2026, not tried against the
real service): a WebSocket at `wss://api.openai.com/v1/realtime?intent=transcription`. After it
opens, the app sends its settings (`session.update`), then the sound in small pieces
(`input_audio_buffer.append`, plain 16-bit samples at 24,000 a second, base64), and at the end
one `input_audio_buffer.commit`. The text comes back in pieces
(`conversation.item.input_audio_transcription.delta`) and then whole (`...completed`).

Two models work there, and the difference matters:

| Model | In a live session | Price (per minute of audio) |
| --- | --- | --- |
| `gpt-live-transcribe` | writes the text while the sound arrives | $0.017 |
| `gpt-transcribe` (our default) | starts only when the sound is committed | $0.0045 |

So `gpt-transcribe` in a live session would save the upload and nothing else: perhaps a tenth
of a second for a short clip. The real gain needs `gpt-live-transcribe`, which costs almost four
times as much per minute and is a different model, so its accuracy has to be judged by ear.
**That is the owner's choice, and the code does not make it for them.** The live path is used
only when the transcription model in Settings is `gpt-live-transcribe`. With any other model
it is skipped before anything is sent, and nothing about a dictation changes.

**How it is built.**

- A new seam, `LiveTranscriber` (`packages/domain`, `Seams.swift`). Its adapter is
  `OpenAILiveTranscriber` (`packages/ai`, `LiveTranscriber.swift`).
- `AudioCapture` can now hand over the sound while it records: `CaptureRequest.liveFrames` and
  `CaptureSession.frames`. They are the very samples that go into the file. The file is written
  in every case.
- `DictationEngine` takes an optional `liveTranscriber`. With one, a session is opened at key
  down and fed as the person speaks. At key up the live side gets a short head start (1.5 s plus
  a tenth of a second per second of speech, 6 s at most). If it has not answered by then, the
  recorded file is uploaded as well, and whichever answers first is used. The file is used at
  once, with no head start, when the session could not be opened or is still being opened,
  when it failed, when some of the sound did not reach it, or when it says nobody spoke (a
  recording is never dropped on the live side's word alone). After that, dictionary, tidying, snippets and inserting are exactly
  as before.
- `DictationEngine.partialText` holds what has been heard so far, for the pill to show later.
  No screen uses it yet.
- The key goes only to the server it was saved for, in the WebSocket handshake too. An address
  that cannot be used opens nothing. A retry of a failed dictation, and every meeting, use the
  file path. If `gpt-live-transcribe` is the chosen model, files go to `gpt-transcribe`,
  because the live model does not take files.

**What was not proven when this was written.** (It has since been tried: see "Tried against
OpenAI" below.) **Nothing had been tried against OpenAI itself**, because no key was
available. The adapter follows the protocol as the documentation describes it. Things only a real key can
show: whether the handshake and the settings are accepted as written, whether 24 kHz samples
made from our 16 kHz recording are fine, how fast the final text really arrives, how long a
recording a session takes, and how good `gpt-live-transcribe` is next to `gpt-transcribe`.
If any of it is wrong, the result is a normal dictation over the file path, a little later
than without the live side (the head start), and `timing.path` in the history says `file`.

**To switch it on**, two things are needed, and until both are done nothing changes:

1. The apps pass the live adapter in. One line where each app builds its model
   (`apps/macos/Sources/SpacesApp/Composition.swift`,
   `apps/ios/Phone/Sources/SpacesPhone/PhoneSession.swift`), next to `transcriber:`:

   ```swift
   transcriber: openAI.transcriber,
   liveTranscriber: openAI.liveTranscriber,
   ```

2. The person sets the transcription model to `gpt-live-transcribe` in Settings (the field takes
   any name). It is not in the list of suggestions: adding it there is a product and price
   decision.

A weakness to know about: a live session that opens fine but never answers costs every
dictation its head start (about 2 s) until the model is changed back. The timings will show
it (`path` is `file`, and `transcribeMs` is long). A rule that turns the live side off for a
while after a few such misses would fix that, and is not written yet.

## Tried against OpenAI, 20 November 2026

The live path was tried for real for the first time, with the owner's key, from the owner's Mac.
No microphone was used: the speech was made with the Mac's own `say` voice (a 6.8-second
sentence, 16 kHz), and fed to `OpenAI.liveTranscriber` at the speed a person speaks, 0.1 s at a
time. The same file then went through the file path. Three runs each.

| | Live (`gpt-live-transcribe`) | File (`gpt-transcribe`) |
| --- | --- | --- |
| Opening the session (while speaking) | 1.2 to 2.0 s | none |
| From the last sound to the text | 0.86 to 0.96 s | 1.5 to 2.1 s |
| Text | right; kept the "Um", wrote "three p.m." | right; dropped the "Um", wrote "3 p.m." |

The handshake, the settings and the 24 kHz samples are all accepted as written. The text pieces
arrive while the sound is sent (29 updates for the sentence). The tidy-up step removes the
filler and writes the number, so after it both paths give the same sentence.

**What changed.** `gpt-live-transcribe` is now the default for a new install and is first in
the list in Settings. A setting saved before keeps its model. The price is the one in the
table above: about four times as much per minute of speech, for about a second less waiting.

Opening takes up to 2 s, so a dictation shorter than that may find the session still opening
when the key comes up. Such a dictation uses the file at once, as before.

### Tidying, measured

The app's own clean-up prompt, sent to each model four ways (the four sentences below come from
the owner's history), twice each, on one open connection:

| Model | Middle time | Slowest | What came back |
| --- | --- | --- | --- |
| `gpt-6-luna` (default) | 1.0 to 1.3 s | 2.0 s | right every time |
| `gpt-6-luna`, `service_tier: priority` | 0.82 s | 1.08 s | the same text |
| `gpt-5.6-luna` | 0.95 s | 1.6 s | right |
| `gpt-5.4-mini` | 0.88 s | 0.97 s | kept a filler, dropped a capital letter |
| `gpt-5.4-nano`, `gpt-4.1-mini` | about 1.05 s | 1.5 to 1.9 s | kept fillers and false starts |
| `gpt-6.1-terra` | 1.7 s | 2.6 s | slower, and left words out |

The app's own client took the same time as a bare request (middle 1.03 s), so nothing in the app
adds to it. The 1.7 to 2.4 s in the owner's history were longer dictations, sent over a VPN.

So the default model stays. Only the priority tier is clearly faster with the same text: about
0.2 s in the middle and 0.4 s in the slow cases. OpenAI charges more for it, so it is not
switched on; that is the owner's call.

## Still a proposal

### Transcribing on the Mac itself

This is what makes T3 Code feel instant: no network at all, and the model listens while you
speak. Two ways to get there:

- **Apple's speech framework** (macOS 26 and later has a new on-device transcriber). No
  download we have to host, no cost per minute, works offline. Unknowns: accuracy next to
  `gpt-transcribe`, especially for names and mixed languages; whether custom words are
  supported well enough; and it needs a newer macOS than the app's minimum (14.4).
- **A bundled open model** (Parakeet or Whisper through a C++ engine, as T3 Code does). Best
  speed and quality on Apple Silicon, but it means a third-party dependency (the project rule
  is none without a strong reason), a download of several hundred megabytes that the person
  must agree to, and model files to keep up to date.

Recommendation: do not start here. First read the real timings from a few days of use. If
upload plus transcription is the big number, try `gpt-live-transcribe` with a real key, since
that path is already written. If the owner then still wants the T3 Code feel, or wants
dictation to work offline, build the Apple speech adapter as a third `LiveTranscriber`: the
seam, the live sound from the capture and the fallback to the file are already in place, so it
is an adapter and a setting, not a redesign. A bundled model is the last resort, because of the
dependency and the download.

### Smaller ideas, not done

- **Ask for the transcript as a stream** (`stream=true` on the file upload). The first bytes
  would arrive sooner, which would let a stall be noticed sooner still. It changes how the
  reply is read, and custom servers may not support it.
- **Hand the file over before the microphone has fully closed.** Closing the audio engine
  takes a little time after the last sound is in. Worth a look only if `captureMs` turns out
  large, and only with a real microphone to test on.
- **Send the file and the live session together from the start** when the connection is good,
  and take the first answer. Faster in the worst case, but it pays for every dictation twice.

## Needs a person

- A day of real dictation on the owner's VPN, then read `timing` from `dictations.json`
  (numbers only) to see where the time goes and whether any dictation still fails.
- Whether a time-out still happens at all, and if it does, what `transcribeMs` was on the
  failed entry (about 17 s means both tries got no answer; a few seconds means something else).
- The live path with a real key: pass `liveTranscriber` in, set the model to
  `gpt-live-transcribe`, dictate, and check that `timing.path` says `live`, that the text is
  right, and what `transcribeMs` is.
- Whether the price of `gpt-live-transcribe` is acceptable, and whether to offer it in the
  model list.
- `captureMs` with a real microphone (it was not recorded here: no recording was allowed).

## More ideas from T3 Code, not built yet

Read from its public voice documents. Ideas only; no code was taken.

- **Spoken corrections.** Its clean-up fixes "make it 42, sorry, 24", and a cue phrase such as "scratch that" can be set.
- **Skip the clean-up.** While the text is being tidied, a Skip button inserts the raw words at once.
- **Clean-up sees the text around the cursor** (up to about 1,000 characters), so the result fits what is already written.
- **Note where the text will go before recording, and check again before inserting,** so a late result cannot land in the wrong place.
- **Two test buttons:** "Test microphone" plays your voice back and sends nothing; "Test model" shows what the model heard, with no clean-up.
- **Transcription on the Mac itself.** This is where its instant feel comes from. See the proposal above.
