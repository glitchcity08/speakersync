# Speaker Sync

SpeakerSync is a small background Mac app that plays all of my Mac's audio on two speakers at once, the PreSonus **Eris 4.5BT** and the **Brane** (both Bluetooth), and keeps them in time. Bluetooth speakers have different, drifting delays, so the app holds the faster speaker back and keeps listening through the MacBook mic to correct the drift live. It's for my room: playing music on both speakers without an echo.

**Stack:** Swift, Core Audio and AppKit (menu bar), no dependencies. The model is in `01 Measurements & Findings/(C) Sync Model.md`. Source code is in `02 Build/src/main.swift`. The built app is at `~/.local/speakersync/SpeakerSync.app`, and `~/.local/speakersync/src` is a link back to this folder.

## Claude's Role

Claude is the audio engineer on this app. Its job is to keep the sync tight, find out why it drifts (from the log and the mic measurements, not by guessing), and keep the app stable enough to run all day in the background.

If a session is drifting without making the speakers sound more in sync, nudge me back: "Does this change make the two speakers hit together, and did we measure it with the mic?"

## Process

1. **Idea:** Capture a fix or feature in `00 Ideas & Features/`.
2. **Measure:** Before changing the sync logic, take readings (log, `sync-status`, mic) and write the numbers in `01 Measurements & Findings/`.
3. **Build:** Change `02 Build/src/main.swift`, rebuild and sign with the command in `04 System/(C) Build & Run.md`.
4. **Verify:** Watch `sync-status` and `log.txt` for at least a minute with music playing. Errors under about 6 ms count as in sync.
5. **Review:** Update the dashboard in `03 Dashboard/` and log what's still off in `07 Iteration Logs/`.

## Folder Structure

- `00 Ideas & Features/`: fixes and features to try
- `01 Measurements & Findings/`: what the measurements showed about each speaker's delay and drift
- `02 Build/`: the app's source (`src/main.swift` is current, `src/main_v1.swift` is the old fixed-delay version)
- `03 Dashboard/`: `(C) SpeakerSync Dashboard.html` (published snapshot of the session's data + math simulator) and `(C) Live Dashboard.html` (real-time page that SpeakerSync serves at http://localhost:8765, loopback only; `~/.local/speakersync/live.html` links to it)
- `04 System/`: how to build, run, stop and debug the app
- `05 Skills/`: skill markdown files (NOT Claude Code skills)
- `06 Attachments/`: screenshots and recordings
- `07 Iteration Logs/`: what still sounds wrong and what to try next

## Rules & Conventions

- **`(C)` prefix:** Files created by Claude are prefixed with `(C)` so it's clear they're AI-generated. Code in `02 Build/` is exempt.
- **Editing rule:** Edit existing notes freely and say what changed (Viv OS rule).
- **Skills:** All reusable scripts/automations are saved as markdown files in the Skills folder, NOT as Claude Code skills.
- **Measure, don't guess:** The delays the speakers report to macOS are wrong (the Eris reports 94 ms but actually lags about as much as the Brane). Only trust mic measurements.
- **Sign with the fixed identity:** Always sign with `-r='designated => identifier "local.vivos.speakersync"'`. Without it, every rebuild makes macOS ask for mic permission again.
- **Dashboard look:** dealt with the taste skill (`design-taste-frontend`, kind software/devtool). Since 2026-11-15: palette **soot-pale-lime** (`#0f0f0f` ground, `#1a1a1a` panels, `#dafa9c` lime for "in time" and actions), **Familjen Grotesk + IBM Plex Mono**, sharp 2px corners, hairline panels. Speaker colours: Eris near-white `#ededed`, Brane coral `#ff9e7a`, JBL sky `#8ec9ff`. No gradients, glass, emoji or violet. The skill's finish gate is for marketing pages, so it stays disarmed here. (Was graphite-safety-orange / Host Grotesk until 2026-11-14.)
- **Standby apps:** SpeakerSync stands by while any app in `standbyApps` (rekordbox) is open. The earlier finding that excluding rekordbox from the tap stalls it may really have been a stale System Audio Recording permission; retest before relying on it.
- **Stalled capture = stale permission:** if the tap delivers nothing, remove and re-allow SpeakerSync under Screen & System Audio Recording. Restarting coreaudiod doesn't fix it. Never route the Brane into a DJ set, because its ~300 ms Bluetooth delay can't be removed.

## Current Status

> **Last updated:** 2026-11-14 (late)
> **Status:** v3 (iteration 17). **A sweep at launch** (and when the speakers change or on Re-calibrate). While listening: readings every 0.25 s, the same-side rule against hunting, inaudible 10 ms nudges to name a slipping speaker, and a **quiet re-lock** (no sweep, nothing muted) on stream drops, delay changes and unowned spikes. The **Eris is pinned as reference** (menu: Reference speaker). Per-speaker Levels sliders. The live dashboard has been redesigned (soot-pale-lime). Open: CPU ~10% at 0.25 s; Eris hard to pick out in music; the Brane's delay settles ~30 s after a stream start. **Untested:** wired mode.

<!-- TODO: test wired mode once the Eris is plugged into the headphone jack -->
