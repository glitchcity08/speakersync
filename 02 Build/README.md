# SpeakerSync

Play your Mac's audio on two or more speakers at once, in time. SpeakerSync listens through a microphone, hears how far apart the speakers are, and keeps correcting them while the music plays. Bluetooth speakers, wired outputs and the built-in speakers can be mixed.

macOS 27+ only. Single-file Swift app, no dependencies.

## How it works

1. A Core Audio **process tap** captures everything the Mac plays and mutes the original.
2. Each chosen output plays that audio from a shared buffer. The **slowest** output is the reference, and every other output is held back to match it.
3. The mic recording is cross-correlated against the audio that was sent (**GCC-PHAT**). Each speaker shows up as its own spike, and the gap between spikes is the sync error.
4. Per output, SpeakerSync corrects by the **median** of recent readings, so one-off Bluetooth jumps are ignored. It also learns and cancels each output's **drift rate**.
5. **Self-tuning:** each output scores its own sync rounds (time in sync, average error, number of corrections) and learns which correction settings work best for it. It also learns its own measurement noise. All of this is saved per device.

The full model, with the reasoning behind every rule, is in `01 Measurements & Findings/(C) Sync Model.md`.

## Build

```bash
mkdir -p ~/.local/speakersync && cd ~/.local/speakersync
# SpeakerSync.app/Contents/Info.plist needs NSMicrophoneUsageDescription, NSAudioCaptureUsageDescription and LSUIElement
swiftc -O -swift-version 5 -target arm64-apple-macosx27.0 src/main.swift -o SpeakerSync.app/Contents/MacOS/SpeakerSync
codesign -s - --force -r='designated => identifier "local.vivos.speakersync"' SpeakerSync.app
open SpeakerSync.app
```

The `-r=` requirement keeps the app's identity stable across rebuilds. Without it, macOS asks for permissions again after every build.

## Use

- **Menu bar icon:** choose the outputs to sync and the microphone, re-lock, pause, or open the live dashboard.
- **Live dashboard:** `http://localhost:8765`, served by the app and reachable only from this Mac.
- **Lock-in:** each output plays alone for ~2.5 s so SpeakerSync can learn which spike is which. Music has to be playing.
- **Standby apps:** while any app in `standbyApps` is open (rekordbox by default), SpeakerSync stays out of the way.

## Files (`~/.local/speakersync/`)

| File | Contents |
|---|---|
| `config.json` | Chosen outputs (device UIDs), mic, reference, standby apps, paused |
| `devices/*.json` | Per-device memory: learned drift rate, hold-back, self-tuning history |
| `log.txt` | Locks, corrections, learning rounds, errors |
| `status.txt` | Current state, rewritten every ~0.75 s |

## Permissions and troubleshooting

- Needs **Microphone** and **System Audio Recording**.
- **Capture stalled** (log says "capture stalled", dashboard stuck on "collecting audio"): the System Audio Recording entry has usually gone stale after an app change. It shows as on, but macOS feeds the app nothing. Remove SpeakerSync from System Settings → Privacy & Security → Screen & System Audio Recording, relaunch, and click Allow.
- Several Bluetooth speakers share one radio, so 3+ can stutter regardless of sync.
- Total latency is the slowest speaker plus ~90 ms. That's fine for music and wrong for video or DJing.

## Status

Personal project, written so it can be opened up later. Before a public release it still needs a Developer ID signature and notarization, an app icon, a first-run guide, and a license.
