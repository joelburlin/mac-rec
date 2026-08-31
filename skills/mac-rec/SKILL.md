---
name: mac-rec
description: Record the macOS screen programmatically — start/pause/rewind/resume/stop a real screen recording, capture a display, a window, or a dragged region, then produce a compressed MP4 with auto-captions, cleaned narration, or an AI voiceover. Use whenever the user asks to record the screen, capture a demo, film a walkthrough or bug repro, "show me what happens when…", make a screencast, re-narrate a video with an AI voice, or burn captions into a video. Drives the mac-rec daemon over its CLI/REST API, so an agent can record itself working.
---

# mac-rec

A native macOS screen recorder built to be driven by an agent. Every verb is a
CLI command and a localhost REST call, so you and the human share one recorder:
either can start a take, and either can stop it.

## Check first

```bash
mac-rec status --json     # {"state":"idle|recording|paused|finalizing", ...}
```

`state` is the source of truth — never assume. If the binary is missing, tell
the human to install it (https://screenrecording.dev); do not try to
record with `ffmpeg` or `screencapture` instead.

## The loop

```bash
mac-rec start --json                          # full screen, main display
mac-rec start --source window --query "Chrome" --json
mac-rec start --area "x,y,w,h" --display 1 --json   # region, display points
mac-rec pause --json
mac-rec rewind 10 --json                      # drop the last ~10s, fragment-granular
mac-rec resume --json
mac-rec stop --output ./demo.mp4 --json       # concat → HEVC → captions
```

Every command takes `--json`. `stop` blocks through the whole finalize
(compression, transcription, optional voiceover) and can take minutes on a long
take — do not time it out at 30s, and never issue a second `stop`.

`mac-rec list` prints capturable displays, windows (with ids), and microphones.

## Rules that matter

- **One session at a time.** `start` while recording returns 409. Check
  `status` first.
- **Rewind requires paused.** Pause, rewind, then resume. It deletes whole
  ~2s fragments, so it always drops *at least* what you asked.
- **Never leave a session open.** If you started it, stop it — an abandoned
  recording keeps writing to disk.
- **The human may be mid-take.** If `status` shows a session you did not
  start, ask before touching it.
- **Permissions are the usual failure.** "declined TCCs" / "no displays found"
  means Screen Recording is not granted to the host app. Say that plainly;
  it needs a human in System Settings.
- **Recording captures the real screen.** Warn before recording full screen if
  the human may have private content open; prefer `--source window` or
  `--area`.

## Producing the deliverable

```bash
mac-rec stop --captions bold --json           # burn in captions
mac-rec stop --voiceover --json               # replace narration with an AI voice
mac-rec stop --trim-start 3 --trim-end 42 --json
mac-rec stop --no-transcribe --no-compress --json
```

Caption styles: `none | classic | boxed | bold | karaoke | minimal`.
Voices: `mac-rec voices` (needs an ElevenLabs key); `--voice <id>` overrides
the default. Voiceover speaks each sentence, re-anchors it at its original
timestamp, and rebuilds captions from where the audio actually landed, so
captions always match what is heard.

Any existing video can go through the same pipeline without recording:

```bash
mac-rec voiceover -i input.mp4 --captions karaoke -o out.mp4
```

## Results

`stop` returns `{final, durationSeconds, srt, vtt, transcript, shareURL, notes}`.
**Always read `notes`** — that is where soft failures surface (quiet mic,
transcription skipped, upload failed, voiceover fell back). Report them rather
than claiming a clean run.

Sessions live in `~/Movies/mac-rec/<timestamp>/` with the lossless `master.mp4`
kept beside `final.mp4`. If a `stop` ever fails, the fragments survive:

```bash
mac-rec finalize ~/Movies/mac-rec/<session>   # rebuild the deliverable
```

## REST (same daemon, for non-shell callers)

`127.0.0.1:5757` — `GET /status`, `POST /start|/pause|/resume|/rewind|/stop|/mic`.
Bodies and responses are the JSON shapes above; errors come back as
`{"error": "..."}` with a 4xx/5xx status.
