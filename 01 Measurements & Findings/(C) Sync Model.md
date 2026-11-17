# The Sync Model

How SpeakerSync keeps two or more audio outputs on one Mac in time, using only a microphone. Everything here was learned by measuring an Eris 4.5BT and a Brane on 2026-11-13. See `(C) Findings 2026-11-13.md` for the evidence.

## Principles (learned the hard way)

1. **Never trust reported latency.** Drivers report numbers that can be off by hundreds of ms (the Eris said 94 ms and was really ~300 ms).
2. **Never steer on buffer level.** Bluetooth pulls audio in bursts, so the Mac-side buffer swings ±45 ms while the speaker plays steadily.
3. **Never trust timestamps for pacing.** Tap timestamps are calculated rather than measured, and Bluetooth output timestamps jitter by ~8 ms.
4. **The microphone is the only ground truth.** It hears what actually comes out of the speakers.
5. **Speakers move in three different ways,** and each needs its own handling:
   - **Steady drift** (clock mismatch, ~0.2–0.6 ms/s): learn the rate and cancel it continuously.
   - **Jumps** (20–150 ms, often snapping back seconds later): ignore them unless they last.
   - **Resets** (a new delay every time a stream restarts): re-measure on every start.

## Pipeline

```
system audio ──tap (mutes source)──▶ ring buffer (~12 s)
                                       ├─▶ reference output   plays at  w − H_ref        (clock master)
                                       ├─▶ output 2           free-runs at its own pace + mic shifts
                                       └─▶ output N           free-runs at its own pace + mic shifts
microphone ──▶ maps onto the ring's timeline (host time) ──▶ GCC-PHAT vs sent audio ──▶ one spike per output
```

## Measurement

- **Window:** 1.5 s of mic audio against the same 1.5 s of sent audio, every ~0.75 s.
- **Correlation:** GCC-PHAT with β = 0.75 (whitening that boosts noise less), band 150 Hz–7 kHz, lag range 0–1.1 s.
- **Noise:** correlations are averaged across readings (0.6 old / 0.4 new). The music lines up from reading to reading and room noise doesn't, so the spikes build up. A reading is skipped as unclear when its best spike is under 6× the noise floor.
- **Echoes:** a spike 3–12 ms behind a spike more than twice as strong is a wall reflection, not a speaker.

## Identifying who is who

- **At lock-in,** each output plays **alone** for ~2.5 s while the others are muted. Its spike position is its true delay, and two readings that agree within 2 ms confirm it.
- **The reference** is the **slowest** output, so it needs no hold-back. Every other output is held back to match it. If a different output is the slowest at lock-in by more than 20 ms, it becomes the reference.
- **Tracking the reference spike:** it may move at most 0.05 ms per reading (~4 ms per minute). That's enough to follow slow clock drift between mic and audio, and too slow to be dragged onto a louder, nearby speaker. Without this limit the tracker latched onto the Brane and reported "in sync" while the speakers were apart.
- **With 3+ outputs,** a spike that appears and lasts but can't be matched to a known output is identified by a **probe**: each candidate output is muted for ~1.8 s until the spike disappears.

## Correction (per output)

| Situation | Action |
|---|---|
| Median of the last 5 readings within ±6 ms | In time, so no change |
| Median 6–50 ms | Slide the output by 0.6 × median at ≤4 frames per 512 (≤0.8 % speed, inaudible) |
| Median over 50 ms | Jump straight there |
| Output needs to play earlier than its buffer allows | Hold the reference (and so every output) back further |
| Each small correction (<20 ms) | Drift rate += 0.3 × error / time since the last correction, capped at ±0.6 ms/s, saved per device |

A device's learned drift rate and delay are stored under its device ID, so a reconnect starts already compensating.

## Added after the 3-output iterations (2026-11-14)

See `07 Iteration Logs/(C) Iteration Log 2026-11-14.md` for the measurements behind each one.

- **Loudness fingerprint:** each output's spike height relative to the reference, measured at lock-in and refined whenever identity is confirmed. Spikes are attributed by expected position **and** height, and a stray too weak to be an output is ruled out as that output.
- **Nudge identification:** when a stray spike outside the in-time band lasts (3 of 6 readings) and can't be attributed, candidates are slid 10 ms one at a time; the one whose spike moves owns it. Inaudible, at most every 6 s. (This replaced muting, which caused 2 s dropouts.)
- **Room reflections:** a stray two nudges couldn't match is ignored for the rest of the session.
- **α-β reference tracker:** a learned velocity follows the capture-vs-mic clock drift (~0.5 ms/s with a Bluetooth clock), while the 0.05 ms-per-reading slew limit still blocks hijacking. If the reference spike is lost for 8 readings while the strongest spike holds still, the tracker re-anchors there.
- **Honest accounting:** each reading is *assigned* (known error), *merged* (no stray near, so in time) or *unknown* (an unattributable stray outside the band). Unknowns are never scored, corrected on or learned from.
- **Efficiency:** noise floor from every 8th correlation value, ±350 ms scan while tracking, reused buffers, every 1.5 s once all outputs have been in time for 60 s. CPU 3.0% → 1.3%.

## Limits

- An output can never play earlier than its own Bluetooth delay, so total latency equals the slowest output plus ~90 ms. That's fine for music and wrong for video lip-sync or DJing.
- **One mic can't tell equally loud speakers apart from a single reading.** Identity then needs a nudge, and up to ~40–65% of readings can be unknown. Placing the mic nearer one speaker, or setting clearly different volumes, fixes it.
- When two outputs are within ~2 ms of each other their spikes merge. That's the goal, but it means "merged" is the in-sync signal.
- Several Bluetooth speakers on one Mac share one radio, so 3+ may stutter regardless of sync.
- Apps on the standby list (rekordbox) are never captured, because excluding a single app from the tap stalls the tap on macOS 27. SpeakerSync stands by while they're open.
