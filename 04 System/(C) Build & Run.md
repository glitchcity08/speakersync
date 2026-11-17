# Build & Run (v3)

## Rebuild after changing the code

```bash
cd ~/.local/speakersync
swiftc -O -swift-version 5 -target arm64-apple-macosx27.0 src/main.swift -o SpeakerSync.app/Contents/MacOS/SpeakerSync
codesign -s - --force -r='designated => identifier "local.vivos.speakersync"' SpeakerSync.app
pkill -TERM -x SpeakerSync; sleep 1; open SpeakerSync.app
```

- `-target arm64-apple-macosx27.0`: the toolchain defaults to macOS 28, and the app won't launch on 27 without this (error -10825).
- The `-r=` requirement keeps the app's identity stable, so macOS doesn't re-ask for the mic after each rebuild.
- `src/main.swift` is v3. `main_v2.swift` (Eris + Brane only) and `main_v1.swift` (fixed delay) are kept for reference.

## Control

Use the **menu bar icon** (two speakers): outputs to sync, microphone, re-lock, open the live dashboard, pause, quit.

## Files in `~/.local/speakersync/`

| File | What it is |
|---|---|
| `SpeakerSync.app` | The app (menu bar only, no Dock icon) |
| `src` | Link to `02 Build/src` in this project |
| `live.html` | Link to `03 Dashboard/(C) Live Dashboard.html`, served at http://localhost:8765 |
| `config.json` | Outputs (device UIDs), mic, reference, standby apps, paused |
| `devices/*.json` | Per-device learned drift rate, hold-back and self-tuning rounds |
| `log.txt` | Every lock, correction, learning round and error |
| `status.txt` | Current state, rewritten every ~0.75 s |

## Permissions

Needs **Microphone** and **System Audio Recording**.

**If the capture stalls** (log: "capture stalled"; dashboard: `w` stays 0 / "collecting audio"), the System Audio Recording entry has usually gone stale. It shows as on but no longer matches the app. This happened on 2026-11-13 when v2 became the v3 menu bar app. Fix: remove SpeakerSync from System Settings → Privacy & Security → Screen & System Audio Recording, relaunch, and click Allow. Restarting `coreaudiod` did **not** fix it. Note that a test tool run from Terminal or Claude is always silent, because it doesn't have this permission, so it can't be used to diagnose this.
