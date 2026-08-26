# mac-rec

Native macOS screen recorder built for humans **and** AI agents: ScreenCaptureKit
capture, live-rewind via fragmented recording, whisper.cpp auto-captions, HEVC
hardware compression, optional Google Cloud Storage upload — all driveable from
a CLI or a local REST API.

```bash
mac-rec start --source fullscreen        # ● recording
mac-rec pause                            # ⏸ enables rewind
mac-rec rewind 10                        # ⏪ drop the flubbed last 10s
mac-rec resume                           # ● keep going from before the flub
mac-rec stop --output ./screencast.mp4   # ■ concat → compress → captions → upload
```

## How it works

- **Capture**: ScreenCaptureKit (`SCStream`) — full display, a single window, or
  an app's window. System audio comes straight from SCK (no audio driver), the
  microphone is captured on the same stream clock.
- **Live rewind**: while recording, an `AVAssetWriter` in fMP4/HLS mode emits
  ~2-second fragments (`runs/run-NNN/seg_*.m4s`). Rewinding just deletes trailing
  fragment files — no re-encoding, ever. Each pause→resume starts a new "run";
  crash-safety falls out for free (fragments already on disk survive).
- **Mic track**: the HLS writer profile allows one audio track per stream, so the
  mic is a *parallel* audio-only fragment stream started at the same timeline
  zero. At finalize it's trimmed to the kept video duration and muxed back —
  rewind never desyncs it.
- **Finalize** (`stop`): byte-concat fragments → per-run fMP4 → lossless
  `ffmpeg -c copy` concat into `master.mp4` → optional stream-copy trim → HEVC
  (`hevc_videotoolbox`, hardware) `final.mp4` → whisper.cpp `.srt`/`.vtt`/`.txt`
  → optional `gcloud storage cp` upload with the share link on the clipboard.

## Session layout

```
~/Movies/mac-rec/<timestamp>-<title>/
  meta.json            # session state: runs, segments, durations
  runs/run-001/        # init.mp4 + seg_*.m4s (+ mic-init.mp4 + mic_*.m4s)
  master.mp4           # lossless concat (video + system audio [+ mic])
  final.mp4            # HEVC-compressed deliverable (audio mixed to one track)
  final.srt / .vtt / .txt
```

## UI (menu bar + floating HUD + hotkeys)

```bash
./make-app.sh            # builds + installs /Applications/Mac-Rec.app
open /Applications/Mac-Rec.app
```

- **Menu bar**: record full screen, a display, a specific window, or a
  free-style **area** (drag-select overlay, Esc cancels); mic + system-audio
  toggles; pause/resume/rewind/stop; open recordings folder. The icon shows a
  live timer while recording. Missing permissions surface as ⚠️ menu items
  that deep-link the right System Settings pane — screen access auto-restarts
  the daemon once granted.
- **Floating HUD**: a draggable pill (● 0:42 ⏸ ⏪ ■) appears while recording —
  CleanShot-style. It is automatically **excluded from the capture** (the
  daemon filters this app's windows out of the display filter).
- **Global hotkeys** (work everywhere, no Accessibility permission needed):
  - `⌃⌥⌘R` — start → pause → resume (one key drives the flow)
  - `⌃⌥⌘A` — record an area (drag-select)
  - `⌃⌥⌘←` — rewind 10s (auto-pauses if recording)
  - `⌃⌥⌘S` — stop & save (Finder reveals the file when done)
- `mac-rec ui` runs the same UI from a terminal (TCC then attributes to the
  terminal, not the app — prefer the .app).

The app is a thin shell over the same daemon the CLI uses: an agent can drive
a recording while the HUD shows it, and vice versa. Launching the app starts
the daemon under the **app's** TCC identity — grant Screen Recording +
Microphone to "Mac-Rec" once and every client benefits. Add the app to Login
Items to keep the daemon always ready.

## CLI

| Command | Notes |
|---|---|
| `mac-rec start` | `--source fullscreen\|window\|app`, `--display N` / `--display-id ID`, `--query "Chrome"` / `--window-id ID`, `--area "x,y,w,h"` (display points, top-left origin), `--no-mic`, `--no-system-audio`, `--title slug` |
| `mac-rec pause` / `resume` | pause finishes the current run; resume starts a new one |
| `mac-rec rewind <sec>` | paused only; drops **at least** that many seconds, fragment-granular (~2s) |
| `mac-rec stop` | `--output PATH`, `--trim-start S`, `--trim-end S`, `--no-compress`, `--no-transcribe`, `--upload` / `--no-upload` |
| `mac-rec status` | add `--json` (all verbs support it) for agent consumption |
| `mac-rec list` | capturable displays + windows (`--query` filters) |
| `mac-rec setup` | `--whisper-model base`, `--gcs-bucket NAME`, `--whisper-language he`, ... |
| `mac-rec config` | show active config (`~/.config/mac-rec/config.json`) |
| `mac-rec serve` / `quit` | run / stop the daemon manually (CLI auto-spawns it) |

## REST API (for agents / future menu-bar UI)

The daemon listens on `127.0.0.1:5757` (configurable). All bodies are JSON.

```
GET  /health            GET  /status
POST /start             {"source":"fullscreen","display":1,"mic":true,"systemAudio":true,"title":"demo"}
POST /pause             POST /resume
POST /rewind            {"seconds": 10}
POST /stop              {"output":"/tmp/out.mp4","compress":true,"transcribe":true,"trimEnd":42.0}
POST /quit
```

Errors come back as `{"error":"..."}` with a 4xx/5xx status. `/stop` blocks
until finalize completes (CLI waits up to 30 min).

## Permissions (one-time, per hosting app)

TCC attributes permissions to the app that (transitively) spawned the daemon —
your terminal, or the agent's host app (e.g. cmux):

- **Screen & System Audio Recording** — required for any capture.
- **Microphone** — required for `--mic` (the default). If a recording fails with
  "user declined TCCs", enable the host app in System Settings → Privacy &
  Security → Microphone (a previously dismissed prompt won't re-appear).

## Setup

```bash
swift build -c release
ln -sf "$PWD/.build/release/mac-rec" /opt/homebrew/bin/mac-rec

# captions: download a whisper model (or point config at an existing ggml .bin)
mac-rec setup --whisper-model base        # multilingual; base.en for EN-only

# uploads (optional)
mac-rec setup --gcs-bucket my-bucket --gcs-prefix screencasts
gcloud auth login                         # once, for the uploading user
```

External tools used at finalize (not needed during capture): `ffmpeg`,
`whisper-cli` (brew `whisper-cpp`), `gcloud` (upload only).

## Design notes / gotchas

- Rewind granularity is one fragment (~2s) and rounds **up** (you always lose at
  least what you asked). Fragment length is `segmentSeconds` in config.
- Trim is stream-copy, so cut points snap to fragment keyframes (~2s grid). A
  frame-exact trim would need a re-encode — deliberate MVP trade-off.
- The compressed `final.mp4` mixes system audio + mic into one AAC track;
  `master.mp4` keeps them as separate tracks for editing.
- Sessions that fail finalize keep their fragments on disk (`meta.json` has the
  full segment map) — everything is rescuable by hand with ffmpeg.
- One recording session at a time (enforced by the daemon).

## Roadmap

- Live-rewind slider in the HUD (scrub the fragment timeline while paused,
  instead of fixed 10s/30s steps).
- Signed-URL uploads for private buckets (currently plain object URL).
- Frame-exact trim via smart re-encode of the boundary GOPs only.
- Configurable hotkeys.
