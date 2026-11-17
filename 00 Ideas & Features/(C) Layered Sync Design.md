# Layered sync design: calibrate + spot-check (2026-11-14)

**Goal:** a general way to keep any 2+ outputs on one Mac within **±5 ms** (no audible echo), speakers in the same room, without steering continuously from the mic.

**Why change:** v3 uses the mic for everything, every 0.75 s. Most of its failures came from steering by an uncertain signal: telling equally loud speakers apart, reflections, runaway drift learners, and buffers that only grew (0.32 s extra delay and 2–4 s follower buffers, found 2026-11-14).

## The four layers

| Layer | Job | Tool | Mic? |
|---|---|---|---|
| 1. Clock | Cancel clock-rate differences between outputs | Each output's own audio timestamps (sample time vs host time) → resample | No |
| 2. Calibration | Measure each output's fixed latency | Each output plays a test code **alone** → no identity problem | Once per stream start |
| 3. Events | Know when calibration has gone stale | Reconnects, sample-rate/route changes, overloads, timestamp discontinuities | No (if the experiments show it works) |
| 4. Verification | Catch what layers 1–3 miss | Inaudible ultrasonic codes, one per output, every few seconds | Occasional |

## Experiments (SyncLab, `02 Build/lab/`)

Each one has a pass line written **before** running it.

**A. Calibration repeatability** (~4 min, audible sweeps + inaudible codes)
- Each output alone, 8 reps: an audible 0.5 s sweep, then an ultrasonic code. Every other rep restarts the output's stream.
- **Pass:** spread (max − min) within one stream ≤ 2 ms; audible vs ultrasonic agree within 2 ms.
- **Key question:** does Bluetooth latency change on **every stream start**? If so, calibration must run at each start, not once per device.

**B. Open-loop drift and jumps** (30 min, inaudible)
- All outputs play together with **no corrections**. Each repeats its own ultrasonic code once a second in its own time slot, and the mic records everything. Every audio callback timestamp and device event is logged.
- **Measures:** each output's offset vs the reference every second (ground truth), and the clock drift the timestamps predict.
- **Pass, layer 1:** timestamp-corrected offsets stay within ±2 ms over 30 min, apart from jumps.
- **Pass, layer 3:** most mic-measured jumps (≥ 5 ms) line up with a timestamp anomaly or device event within ±2 s.
- If layer 3 fails, the design needs the mic spot-check (layer 4) often enough to bound a jump's audible time, e.g. every 3 s.

**Caveats:** the codes sit at 19–21 kHz, −42 dBFS: inaudible to Vivaan at −40 in the 2026-11-14 test, but dogs and cats hear it. SpeakerSync is paused during the runs.

## Results so far

- **Experiment A ran twice (2026-11-14).** See `01 Measurements & Findings/(C) Latency Stability Test 2026-11-14.md`.
- Latency changes on every stream start, by up to 230 ms, so the design is **calibrate at each stream start and keep streams open**.
- Within a stream: the JBL holds to ±0.1 ms, the Brane to ±1.5 ms, and the Eris wanders up to 13 ms after a start.
- **The ultrasonic codes fail on the Brane and are offset 14–29 ms on the Eris.** Layer 4 must use the audible band (music or a quiet sweep), and experiment B's ultrasonic method can't measure the Brane.
