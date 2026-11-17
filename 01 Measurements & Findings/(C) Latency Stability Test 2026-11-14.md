# Latency stability test (2026-11-14)

**Question:** can a speaker's latency be measured once and reused, or does it change? That decides whether a general sync engine can run on a saved calibration instead of listening to the mic all the time.

**How:** SyncLab `calibrate` (`02 Build/lab/`) plays each speaker alone 8 times: an audible 0.5 s sweep (200 Hz–12 kHz, −20 dBFS) and an ultrasonic code (19–21 kHz, −40 dBFS). The output stream is stopped and restarted before reps 3 and 6. Latency = when the MacBook mic hears it − when macOS says it handed that sample to the speaker. Two runs: 16:32 (the Brane's first reps were disturbed by SpeakerSync shutting down) and 16:36 (clean). Room quiet, SpeakerSync off.

## Results (audible sweeps)

| Speaker | Within one stream | Across stream restarts | macOS reports |
|---|---|---|---|
| JBL Clip 5 | **±0.1 ms** (run 2), 1.2 ms (run 1) | 249 → 257 → 251 ms; run 1: **392 → 252 ms** | 112 ms |
| Eris 4.5BT | wanders up to **13 ms** (ramps after a start, then ±2 ms) | 285 → 237 → 237 ms; run 1: 265 → 242 → 266 ms | 83 ms |
| Brane | ±1.5 ms | **434 → 560 → 330 ms**; run 1 settled at 407 ms | 365 ms, 395 ms, 515 ms, 2.1 s (changes on restarts, unrelated to the real value) |

## What it means

1. **A saved per-speaker calibration can't work.** Every time an output stream starts, Bluetooth renegotiates its buffer, and the latency moves by up to 140 ms (JBL), 48 ms (Eris) and 230 ms (Brane).
2. **Within one running stream, latency mostly holds.** The JBL holds to 0.1 ms and the Brane to ~1.5 ms. The Eris wanders up to 13 ms right after a start, then settles to ±2 ms.
3. **macOS's reported latency is useless as a number.** It's 2–3× too low for the JBL and Eris, and random for the Brane. But the Brane fires a "latency changed" notification exactly when its stream restarts, so it's a usable **event** (layer 3).
4. **Ultrasonic codes don't generalise.** The Brane barely reproduces 19–21 kHz (detections 7–38×, wrong times). The Eris's codes arrive a constant 14–29 ms before its sweeps, probably frequency-dependent delay in its DSP. Verification has to use the audible band: the music itself, as v3 does, or a quiet sweep.

## Design consequence

- **Keep every output stream open for the whole session** (play silence, never stop). Stream starts then only happen at launch, reconnect or a sample-rate change.
- **Calibrate at every stream start**, one speaker at a time with a sweep. That gives no identity problem and is ~10× more precise than locking to music.
- **Trust the stream between starts**, verify occasionally from the music, and re-calibrate on events. Still open: does latency hold over **30+ minutes** within one stream (SyncLab `openloop`)?
