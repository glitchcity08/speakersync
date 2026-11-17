# Open Issues

- [x] **Test 3 outputs:** done with the JBL Clip 5 over 8 measured iterations (see `(C) Iteration Log 2026-11-14.md`).
- [ ] **Identity with equally loud speakers:** up to 40–65% of readings unknown. Try the mic nearer one speaker, or a second mic.
- [ ] **Test wired mode:** plug the Eris into the headphone jack, choose "External Headphones" in the menu instead of Eris 4.5BT, and turn off the Eris's Bluetooth.
- [ ] **Watch a full self-tuning round** (100 clear readings, ~1.5 min of music) and confirm the round shows on the live dashboard.
- [ ] **Retest the rekordbox exclusion:** the tap stall may have been the stale permission, not the exclusion. If exclusion works, SpeakerSync can run during DJ sets on other outputs.
- [ ] **Brane jumps of 20–150 ms** still cause a few seconds of flam before correction. This is a hardware limit.
- [ ] **Public release, later:** Developer ID signing and notarization, an app icon, a first-run guide, a license.
- [ ] **Ultrasonic identification (decided 2026-11-14: not building).** Viable (inaudible at −50 dBFS, detected 13–23 dB above the room), but no CPU gain and little benefit with 2 speakers. Revisit only if 3+ speakers becomes the normal setup, as a side-by-side test that uses ultrasonic for identity only. See `01 Measurements & Findings/(C) Speaker Identification Test 2026-11-14.md`.
- [ ] **Iteration 10 tracking regression?** First run after the sweep merge: 24/18 alternating corrections and Eris 51% within ±6 ms (iteration 9: 70%). A/B against `main_v3_9.swift` under the same conditions; check whether the sweep-measured and music-measured delay differ per speaker.
- [ ] **Slow tap start (now the main practical blocker):** after a launch, macOS often takes 45 s to 8+ min to start delivering system audio to the tap. It seems to wait for something to play, and nothing (calibration included) can run until then. Seen with both the Brane and the Eris as the clock. Investigate: start the aggregate explicitly, or play a silent stream to wake it.
- [ ] **The Brane changes its own delay mid-stream** (420 → 564 ms on 2026-11-14). Iteration 10 re-calibrates when it notices; consider not using the Brane as the reference when another output is available.
- [ ] **Quiet re-lock at launch (iteration 16):** succeeds about 1 in 3 launches. The Eris (reference) is hard to pick out in music (~25% of passes), and the Brane's delay is still settling for ~30 s after a stream starts. Options: (a) wait ~30 s after launch before scanning and keep the old saved buffers meanwhile; (b) at launch, find only the followers relative to each other and anchor on them; (c) sweep at launch but stay quiet during listening.
- [ ] **CPU at 0.25 s readings ≈ 10%** (iteration 14). Try 0.33–0.5 s, or skip the FFT when the music is steady.
- [x] **4 Bluetooth speakers:** not possible on this MacBook Air. It streams to 3 at most (2026-11-15: connecting a 4th dropped another every time). For a 4th, use the Eris on a cable, a USB Bluetooth transmitter, or JBL Auracast linking.
