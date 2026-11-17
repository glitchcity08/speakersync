# SpeakerSync

A macOS menu bar app that plays all of the Mac's audio on two or more speakers at once (Bluetooth, wired or built-in) and keeps them in time by listening through the mic.

Bluetooth speakers each add their own delay, and that delay changes every time a stream starts. SpeakerSync captures the system audio with a Core Audio process tap, plays it to every chosen output from a shared buffer, and holds the faster speakers back to match the slowest one. A short sweep at launch measures each speaker's delay. After that, it keeps cross-correlating the mic against the music (GCC-PHAT) and nudges any speaker that slips.

**Requirements:** macOS 27+, Apple Silicon, Xcode command line tools. Single-file Swift, no dependencies.

## Build and run

```bash
./"02 Build"/build.sh
```

This builds into `~/.local/speakersync/SpeakerSync.app`, signs it ad hoc with a fixed identity, and launches it. On first launch, allow **Microphone** and **System Audio Recording**. Then pick outputs, mic and reference speaker from the menu bar icon. The live dashboard is at http://localhost:8765 (loopback only).

More detail: [`02 Build/README.md`](02%20Build/README.md) and [`04 System/(C) Build & Run.md`](04%20System/(C)%20Build%20%26%20Run.md).

## Layout

| Folder | What's in it |
|---|---|
| `02 Build/src/main.swift` | The app |
| `02 Build/lab/` | SyncLab, a test harness for measuring speaker latency |
| `02 Build/probe/` | Early probe tool |
| `03 Dashboard/` | Live dashboard served by the app, plus a static report |
| `01 Measurements & Findings/` | What the measurements showed; `(C) Sync Model.md` explains the model |
| `00 Ideas & Features/` | Designs and ideas |
| `07 Iteration Logs/` | Iteration-by-iteration changes and the open issues list |

Files prefixed `(C)` were written with Claude. `CLAUDE.md` is the context file for Claude Code sessions on this project.

## Known limits

- The Mac's Bluetooth radio streams to 3 speakers at most.
- Total latency is the slowest speaker plus a buffer, which is fine for music but wrong for video or DJing.
- Open problems are tracked in `07 Iteration Logs/(C) Open Issues.md`.
