# Findings: 2026-11-13

What one night of measurement showed about the two speakers. Raw data is in `~/.local/speakersync/log.txt`.

## 1. The delays the speakers report to macOS are wrong

| | Reported to macOS | Mic-measured reality |
|---|---|---|
| Eris 4.5BT | 94 ms | about the same as the Brane |
| Brane | 327 ms | ~300 ms, wandering |

The first fix used the reported numbers (hold the Eris back 273 ms). The first beep test showed that was wrong: at 350 ms, the Eris was arriving **340 ms after** the Brane.

## 2. The Eris is rock steady

Across beep tests, the Eris's beep onsets landed at 0.598 / 0.603 / 0.598 s, within ±5 ms. All the instability comes from the Brane.

## 3. The Brane's delay moves around

- **Per startup:** each time its audio stream restarts, its delay settles somewhere new. Lock-in measurements across restarts ranged from 10 ms to 278 ms of difference from the Eris.
- **Within a session:** it jumps 20–90 ms every 10–20 s and often jumps partway back a few seconds later.
- **Slow drift:** between jumps it tends to drift later, about 7 ms every ~12 s.

## 4. The Brane's Bluetooth pulls audio in bursts

The Mac-side buffer swings ±2,000 frames (±45 ms) within seconds, while the Brane plays at a steady rate. Steering on that buffer level made things worse, and version 1 resynced 288 times because of it. v2 lets the Brane play straight through and lets only the mic decide the alignment.

## 5. Timestamps can't be trusted

- Tap capture timestamps had **0** jitter, which means macOS calculates them rather than measuring them.
- Brane output timestamps jittered by up to ~350 frames per buffer.

Neither is reliable enough for pacing. Only the mic measures what actually comes out of the speakers.

## What works now (v2)

The mic hears both speakers and correlates the recording against the audio that was sent (GCC-PHAT). Each speaker shows up as its own peak. After a lock that silences the Brane to identify the Eris peak, it corrects only by the **median of 5 readings**, so spikes that snap back get ignored. Result: about ±5 ms most of the time, with brief 20 ms excursions when the Brane jumps.
