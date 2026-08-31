<div align="center">

# mac-rec

**The macOS screen recorder your agent can drive.**

ScreenCaptureKit capture · live rewind · auto-captions · AI re-narration
One daemon, two operators: you and your agent share the same recording.

[**⬇ Download for macOS**](https://github.com/joelburlin/mac-rec/releases/latest/download/Mac-Rec-0.4.0.dmg) · [Website](https://screenrecording.dev/) · [Agent skill](skills/mac-rec/SKILL.md) · MIT

*macOS 15 (Sequoia) or later · universal (Apple silicon &amp; Intel) · 2.2 MB*

</div>

---

Screen recorders are built for hands. This one is built for both: every verb is
a keyboard shortcut **and** a CLI command **and** a localhost REST call, against
one background daemon. Your agent can start a take, you can stop it from the
floating pill, and neither has to know the other exists.

```bash
mac-rec start --source fullscreen     # ● recording
mac-rec pause                         # ⏸ enables rewind
mac-rec rewind 10                     # ⏪ drop the flubbed last 10s
mac-rec resume                        # ● continue from before the flub
mac-rec stop --output ./demo.mp4      # ■ concat → compress → captions
```

## Why it exists

An agent that can *see* a screen still can't *show* you one. Driving a GUI
recorder means clicking through dialogs no API exposes. mac-rec inverts that:
the GUI is a thin shell over a documented local API, so recording a bug repro,
a product demo, or a walkthrough is three shell commands — with a human able to
take over mid-take.

## Features

- **Live rewind** — recording streams into ~2-second fragmented MP4 chunks.
  Rewinding deletes trailing fragments; nothing is ever re-encoded. Resume
  starts a new run, and stop concatenates what survived, losslessly.
- **Capture anything** — a display, a single window (by id or name), or a
  dragged region, with system audio and microphone as separate tracks.
- **Captions** — whisper.cpp transcription with word timings, five burn-in
  templates (`classic · boxed · bold · karaoke · minimal`) rendered natively
  with CoreText, plus `.srt`/`.vtt`/`.txt` sidecars. Correct bidi, so Hebrew
  and Arabic render properly.
- **AI re-narration** — replace recorded narration with an ElevenLabs voice.
  Each sentence is spoken separately and re-anchored at its original timestamp,
  speed-fit to its slot, and captions are rebuilt from where the audio actually
  landed — so they cannot drift from what is heard.
- **Mic that survives reality** — auto-gain rescues quiet webcam mics, denoise
  and speech-leveling clean the take, live mute mid-recording, and a level
  meter on the floating pill so you never record silence by accident.
- **Hardware compression** — HEVC via VideoToolbox, hardware-accelerated on
  Apple Silicon. The lossless master is always kept alongside.
- **Survives the real world** — displays are kept awake for the whole take, a
  killed capture auto-pauses instead of zombie-recording, and any failed save
  can be rebuilt from the fragments still on disk.

## Install

**macOS 15 (Sequoia) or later.** Needs `ffmpeg` for the finalize pipeline
(`brew install ffmpeg`), `whisper-cpp` for captions, `gcloud` only for uploads.

### Download the app

[**Mac-Rec-0.4.0.dmg**](https://github.com/joelburlin/mac-rec/releases/latest/download/Mac-Rec-0.4.0.dmg) — universal, 2.2 MB. Drag it into Applications, then
**right-click → Open** the first time.

> The build is open source and unnotarized (notarizing needs a paid Apple
> Developer ID), so macOS quarantines the download. That right-click is needed
> once. If macOS still refuses:
> `xattr -dr com.apple.quarantine /Applications/Mac-Rec.app`

### Or build it (skips Gatekeeper entirely)

Requires Swift 6 / Xcode command line tools.

```bash
git clone https://github.com/joelburlin/mac-rec.git && cd mac-rec
./setup-signing.sh     # once: a self-signed identity so permissions survive rebuilds
./make-app.sh          # builds, installs /Applications/Mac-Rec.app, links the CLI
open /Applications/Mac-Rec.app
```

Grant **Screen Recording** and **Microphone** to Mac-Rec on first record. The
app spawns the daemon, so one grant covers the UI, the CLI, and your agent.

> `setup-signing.sh` needs one `security add-trusted-cert` approval (it prints
> the command). Skip it and the app still works — macOS just makes you
> re-grant permissions after every rebuild, because ad-hoc signatures pin TCC
> to the exact binary.

## For agents

Copy the skill into any Claude Code install:

```bash
cp -r skills/mac-rec ~/.claude/skills/
```

Then "record a walkthrough of this bug" just works — the agent checks state,
records, rewinds its own mistakes, and hands back an MP4 with captions. The
skill covers the guardrails that matter: one session at a time, rewind needs
pause, never abandon a take, and always read `notes` for soft failures.

## CLI

| Command | Notes |
|---|---|
| `mac-rec start` | `--source fullscreen\|window\|app`, `--display N` / `--display-id ID`, `--query "Chrome"` / `--window-id ID`, `--area "x,y,w,h"`, `--mic-device NAME`, `--no-mic`, `--no-system-audio`, `--title slug` |
| `mac-rec pause` / `resume` | pause finishes the current run; resume starts a new one |
| `mac-rec rewind <sec>` | paused only; drops **at least** that many seconds (~2s granularity) |
| `mac-rec stop` | `--output PATH`, `--captions STYLE`, `--voiceover`, `--voice ID`, `--trim-start/-end S`, `--mic-gain dB`, `--no-compress`, `--no-transcribe`, `--no-clean-mic`, `--upload` |
| `mac-rec finalize <dir>` | rebuild deliverables from a session's fragments |
| `mac-rec voiceover -i FILE` | re-narrate any existing video |
| `mac-rec status` / `list` / `voices` | state, capture sources + mics, ElevenLabs voices |
| `mac-rec setup` | `--whisper-model base`, `--eleven-key env`, `--caption-style bold`, `--gcs-bucket NAME`, `--mic-gain auto` |

Every verb accepts `--json`.

## REST API

The daemon listens on `127.0.0.1:5757`:

```
GET  /health            GET  /status
POST /start             {"source":"fullscreen","display":1,"mic":true,"area":{...}}
POST /pause             POST /resume
POST /rewind            {"seconds": 10}
POST /mic               {"muted": true}
POST /stop              {"output":"/tmp/out.mp4","captions":"bold","voiceover":true}
```

Errors return `{"error":"..."}` with a 4xx/5xx status. `/stop` blocks until
finalize completes.

## UI

A menu-bar app plus a floating pill (● timer · mic meter · pause · rewind ·
stop) that stays out of the recording. Global hotkeys default to `⌥⌘R` record
/ pause / resume, `⌥⌘A` area, `⌥⌘←` rewind 10s, `⌥⌘S` stop & save — all
rebindable in `~/.config/mac-rec/config.json`.

## How it works

```
SCStream ──▶ AVAssetWriter (fMP4, 2s fragments) ──▶ runs/run-NNN/seg_*.m4s
                                                          │
   rewind = delete trailing fragments ────────────────────┤
                                                          ▼
        byte-concat ─▶ lossless master.mp4 ─▶ trim ─▶ whisper ─▶ [voiceover]
                                                          │
                                    HEVC + caption overlay ▼
                                                     final.mp4
```

The fragment writer allows one audio track per stream, so the microphone rides
a parallel fragment stream on the same clock and is muxed back at finalize —
which is why rewind can never desync it.

## Session layout

```
~/Movies/mac-rec/<timestamp>-<title>/
  meta.json     runs/run-001/     master.mp4     final.mp4
  final.srt     final.vtt         final.txt
```

## Contributing

Issues and PRs welcome. `swift build` to compile, `./make-app.sh` to install
the app locally. Please keep the daemon API backward compatible — agents
depend on it.

## License

MIT — see [LICENSE](LICENSE).
