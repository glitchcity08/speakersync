# Commands & Skills

Quick reference for all available skills and commands in this project.

## Skills (in 05 Skills/)
_No project-specific skills yet._

## Commands

| Command | What it does |
|---|---|
| `open ~/.local/speakersync/SpeakerSync.app` | Start SpeakerSync (does nothing if it's already running) |
| `pkill -x SpeakerSync` | Stop it. Audio goes back to the Eris alone |
| `~/.local/speakersync/sync-status` | Show mode, lock state, current hold-back and last measured error |
| `~/.local/speakersync/sync-relock` | Re-lock: each output plays alone for ~2.5 s (needs music); same as the menu bar's Re-lock |
| Menu bar icon | Choose outputs and mic, re-lock, pause, open the dashboard, quit |
| `tail -f ~/.local/speakersync/log.txt` | Watch lock and drift events live |
| `open http://localhost:8765` | **Live dashboard**: correlation spikes, every reading, the median window, corrections, drift rate and log, updating twice a second (only while SpeakerSync runs) |

Build and signing: see `04 System/(C) Build & Run.md`.
