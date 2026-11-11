# Sotto

**Private meeting notes for your Mac. Every conversation becomes a searchable transcript with speaker labels, recorded and transcribed on your own computer.**

Sotto lives in the menu bar. Click record before a call or an in-person meeting, then click stop. A minute later you have a timestamped transcript that says who said what, saved as plain Markdown in a folder you own. AI apps that speak MCP (Claude Desktop, Claude Code, Cursor and others) can search and read those transcripts through a local connector, so you can ask "what did we agree on with the roofer last Tuesday?" without your recordings going to anyone's cloud.

- **Local.** Audio is recorded, transcribed and split by speaker on your Mac, on the Neural Engine. There is no account and no server. After the speech models download once, it works offline.
- **Real speaker labels.** In a call, your microphone and the computer's audio are recorded as separate tracks, so you are always labeled correctly, and everyone else is split by voice (Speaker 1, Speaker 2...). In person, the whole room is split by voice. Name a speaker once and Sotto recognizes that voice next time.
- **No bot in the meeting.** It works with Zoom, Google Meet, Teams, Slack huddles, FaceTime, a phone on speaker, or anything else your Mac plays.
- **Your files.** Each recording is a folder with the audio, `transcript.md` and `transcript.json`. Nothing is hidden in a database, and the search index can always be rebuilt.
- **Connects to AI apps.** A one-click Claude Desktop extension, a local MCP server for any MCP client, and a token-protected local HTTP API.
- **Free and open source** (MIT).

## Requirements

- A Mac with Apple Silicon (M1 or later)
- macOS 14.2 or later (needed for recording computer audio)
- Xcode or the Xcode Command Line Tools, to build from source
- About 500 MB of disk space for the speech models, downloaded on first use

## Install

```bash
git clone https://github.com/Pixlel-Inc/sotto.git
cd sotto
scripts/build-app.sh --install
open ~/Applications/Sotto.app
```

The waveform icon appears in your menu bar, near the clock. Opening Sotto again from Spotlight or Finder shows the same controls in a window. The first recording asks for microphone access and for permission to record computer audio ("System Audio Recording Only"). The first transcription downloads the speech and speaker models (about 500 MB, once).

Sotto opens at login on its own, so it is back in the menu bar after a restart. To stop that, turn off **Open at Login** under the gear in its menu.

## Using it

**Record anything.** Click **Start Recording**. Sotto always records your microphone and the computer's audio, then works out which kind of conversation it was.

- **If speech came through the computer, it was a call.** Your microphone is "you" and the computer audio is everyone else. Headphones give the cleanest result. Without them, Sotto removes the other side's voice that your microphone picks up from the speakers.
- **If no speech came through the computer, it was in person.** The microphone is split by voice. Put the Mac where it can hear everyone.

**It saves as it goes.** Audio is written to disk continuously. If the Mac shuts down or Sotto crashes mid-recording, the next time Sotto opens it recovers the recording and transcribes it. Putting the Mac to sleep ends the recording and saves it.

**It stops by itself.** After 10 minutes with no words, on the microphone or the computer, Sotto stops and transcribes what it has. Change the time with `autoStopMinutes` in the settings file (0 turns it off).

**It offers when you join a meeting.** When an app holds your microphone for a few seconds, a small drop-down under the menu bar icon offers to start recording. Sotto checks which app is using the mic, so it works with Zoom, Teams, Meet, Webex, Slack, FaceTime, and any white-labeled meeting site or app, and it never looks at your browsing or network traffic. Turn it off with **Offer to Record Meetings** under the gear. Add apps that should never trigger it to `meetingPromptIgnore` in the settings file.

**Import a recording.** Click **Upload Audio File** in the menu, then drop files on the window or choose them (m4a, mp3, wav, aac, caf, flac, aiff, mp4, mov). Your original file is left where it was. Or drop files into `~/Documents/Sotto/Inbox`, and Sotto picks them up within a few seconds and moves them in. Voice memos, phone recordings and files from a hardware recorder all work.

**Read and name speakers.** Click a recording to open its transcript. To put a name on a speaker, tell your AI app ("Speaker 2 is Dana"), or run:

```bash
sotto rename 2026-11-06_1430 "Speaker 2" Dana
```

Sotto remembers Dana's voice and labels her automatically in later recordings.

**Set your name.** Choose **Your Name** under the gear in the menu so your lines say your name instead of "Me".

### Telling people you are recording

Recording laws vary. Many places, including Pennsylvania, California, Florida, Illinois, Maryland, Massachusetts, Michigan, Montana, New Hampshire and Washington in the US, require **everyone** in a conversation to agree before it is recorded. Sotto has no bot that announces itself, so it is on you to tell people.

By default, Sotto reminds you each time you start recording and offers to copy a short notice you can paste into the meeting chat. You can edit the notice (`consentNotice` in the settings file) or turn off the reminder under the gear in the menu. This is not legal advice.

## Connect an AI app

Sotto's connector is a local [MCP](https://modelcontextprotocol.io) server. It runs on your Mac and reads your recordings folder directly. Your AI app sees only the parts of a transcript it reads to answer you.

Tools it offers: `list_recordings`, `get_transcript`, `search_transcripts`, `rename_speaker`, `set_title`, `recording_status`, `start_recording`, `stop_recording`.

**Claude Desktop.** In the Sotto menu choose **gear > Connect an AI app > Install in Claude Desktop**, then click Install. (The file is `build/Sotto.mcpb` if you would rather double-click it.)

**Claude Code.** Choose **gear > Connect an AI app > Copy Claude Code command** and paste it into a terminal. It looks like this:

```bash
claude mcp add sotto --scope user -- "$HOME/Applications/Sotto.app/Contents/Resources/sotto" mcp
```

**Cursor, Windsurf, VS Code and other MCP clients.** Add a stdio server:

```json
{
  "mcpServers": {
    "sotto": {
      "command": "/Users/YOU/Applications/Sotto.app/Contents/Resources/sotto",
      "args": ["mcp"]
    }
  }
}
```

**Browser chat apps.** claude.ai, chatgpt.com and grok.com in a web browser cannot reach a server on your Mac: their connectors are called from the provider's cloud and need a public internet address. Use their desktop apps where those support local MCP servers, or the local API below with your own tools. Putting your transcripts on a public tunnel is deliberately not built in.

Some things to ask once it is connected:

- "What did I talk about with Dana this week?"
- "Find where we discussed pricing and summarize what was decided."
- "Check my calendar for yesterday's 2pm meeting and pull up the transcript from that time."
- "Speaker 2 in this morning's call is Marcus. Rename him."

## Command line

The app includes a command-line tool. Link it somewhere on your PATH:

```bash
ln -s ~/Applications/Sotto.app/Contents/Resources/sotto /usr/local/bin/sotto
```

```text
sotto record [--room] [--title "..."] [--speakers N]   Record until Ctrl-C, then transcribe
sotto transcribe <file> [--title "..."] [--speakers N] Import an audio file and transcribe it
sotto retranscribe <id> [--speakers N]                 Transcribe a recording again
sotto list                                             List recordings
sotto show <id> [--json]                               Print a transcript
sotto search <words>                                   Search every transcript
sotto rename <id> <speaker> <name>                     Name a speaker
sotto title <id> <title>                               Rename a recording
sotto inbox                                            Process the inbox folder now
sotto models                                           Download the models ahead of time
sotto serve                                            Run the local HTTP API without the app
sotto mcp                                              Run the MCP server on stdio
sotto token                                            Print the local API token
sotto paths                                            Show where files are kept
sotto reindex                                          Rebuild the search index
```

Ids can be shortened to any unique prefix, such as `2026-11-06_14`. When you know how many people were talking, `--speakers N` gives a better speaker split.

## Local HTTP API

While the app runs, it serves an API on `http://127.0.0.1:47820`, reachable from this Mac only. Every route except `/v1/health` needs the token from `sotto token`:

```bash
TOKEN=$(sotto token)
curl -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:47820/v1/search?q=pricing"
```

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/health` | Liveness check, no token |
| GET | `/v1/status` | Version, recording count, whether a recording is running |
| GET | `/v1/recordings?limit=&since=&until=&q=` | List recordings (dates as `YYYY-MM-DD` or ISO 8601) |
| GET | `/v1/recordings/{id}` | One recording with segments as JSON |
| GET | `/v1/recordings/{id}/transcript.md` | The transcript as Markdown |
| GET | `/v1/search?q=&limit=&recording=` | Full-text search; `"quoted phrases"` work |
| POST | `/v1/recordings/{id}/speakers` | `{"speaker": "Speaker 2", "name": "Dana"}` |
| POST | `/v1/recordings/{id}/title` | `{"title": "Weekly sync"}` |
| POST | `/v1/record/start` | `{"mode": "call" or "room", "title": "..."}` |
| POST | `/v1/record/stop` | Stop and queue transcription |

Requests whose `Host` header is not `localhost` or `127.0.0.1` are refused, which protects against web pages trying DNS-rebinding tricks.

## Where things live

```text
~/Documents/Sotto/
  Inbox/                          drop audio here to import it
  Recordings/2026-11-06_143012/
    mic.m4a                       your microphone (16 kHz AAC, about 15 MB an hour)
    system.m4a                    computer audio, for calls
    meta.json                     title, date, tracks, speaker names
    transcript.json               segments: start, end, speaker label, text
    transcript.md                 the readable transcript
    speakers.json                 voice fingerprints for this recording
~/Library/Application Support/Sotto/
  config.json                     settings and the API token
  voices.json                     voices you have named
  index.sqlite                    search index (safe to delete)
```

Set `SOTTO_HOME` to keep recordings somewhere else. Settings you can change in `config.json`: `ownerName`, `consentReminder`, `consentNotice`, `port`, `asrModel` (`v3` multilingual, the default; `v2` English only; `ultra`), `voiceMatchThreshold`, `autoStopMinutes`, `meetingPrompt`, and `meetingPromptIgnore`.

To delete a recording, delete its folder.

## How it works

1. **Capture.** The microphone comes through AVAudioEngine. Computer audio comes through a Core Audio process tap (macOS 14.2+), so no virtual audio driver is needed. Each track is resampled to 16 kHz mono and written as AAC.
2. **Speech to text.** NVIDIA's Parakeet TDT 0.6B, converted to Core ML, runs on the Neural Engine and gives word-level timestamps. An hour of audio takes about a minute on recent Macs.
3. **Who spoke.** The pyannote community-1 pipeline (segmentation, WeSpeaker embeddings and VBx clustering) finds the speaker turns. Each word goes to the speaker whose turn it falls in, and short sentences are kept with one speaker so turn edges do not split a phrase.
4. **Merge.** In a call, the microphone track is you and the computer track is split by voice. Echo of the computer audio picked up by your microphone is removed by matching words and times. Both tracks are merged into one timeline.
5. **Remember voices.** Each speaker's average voice embedding is saved with the recording. When you name a speaker, the voice is added to `voices.json`, and later speakers that match closely enough are named automatically.

Speech and speaker models run through [FluidAudio](https://github.com/FluidInference/FluidAudio).

## Limitations

- Apple Silicon only, because the models are built for the Neural Engine.
- Transcription runs after a recording ends, not live.
- If the computer is playing speech (a video, say) during an in-person conversation, Sotto reads it as a call and labels everyone in the room as you.
- If a recording is cut short by a crash or power loss, the last few seconds may be missing.
- If your output device changes during a call (AirPods connecting, say), computer audio may stop being captured for the rest of that recording.
- Speaker splitting is good, not perfect. Similar voices can merge and one voice can occasionally split in two. `--speakers N` and renaming help.
- No summaries yet. Ask your AI app; that is what the connector is for.

## Roadmap

- A small wearable recorder (ESP32-S3) that syncs into the inbox folder
- Live transcript while recording
- Automatic titles from your calendar
- Signed and notarized downloadable builds

## Development

```bash
swift build                 # debug build of the library, CLI and app
scripts/test.sh             # unit tests
scripts/build-app.sh        # release Sotto.app and Sotto.mcpb in ./build
SOTTO_DEBUG=1 sotto ...     # verbose model logs
```

Set `SIGN_IDENTITY` to a Developer ID certificate name to sign with the hardened runtime instead of ad hoc.

## License

MIT. See [LICENSE](LICENSE).

The speech and speaker models are downloaded from Hugging Face at first use and carry their own licenses: [Parakeet TDT 0.6B v3](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) (CC-BY-4.0) and the [pyannote-based diarization models](https://huggingface.co/FluidInference/speaker-diarization-coreml). FluidAudio is Apache 2.0.

Made by [Pixlel](https://pixlel.com).
