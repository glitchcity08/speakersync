# Iteration Log: 3 outputs (Brane + Eris + JBL Clip 5), 2026-11-14

Goal: use three real outputs to find the model's weak spots, fix them one measured round at a time, and make it as light on resources as possible. Each round deployed one change, waited for the lock, then recorded 4–6 minutes of every reading plus SpeakerSync's CPU and memory. The recorder lives in the session scratchpad (`bench/collect.py`). Previous versions of the source are kept as `02 Build/src/main_v3_*.swift`.

## Results

"In time" = within ±6 ms, out of the readings whose speaker identity was known. "Unknown" = readings where a stray spike outside the in-time band couldn't be attributed (only tracked from iteration 4 on; earlier runs silently counted these as perfect).

| # | Change | Eris in time / avg | JBL in time / avg | Corrections | Dropouts | Unknown | CPU |
|---|---|---|---|---|---|---|---|
| 0 | Baseline v3 | 85% / 3.1 ms | 90% / 3.0 ms | 13 | 18 probes | not tracked | 3.0% |
| 1 | Lean DSP + stricter probes | 57% / 6.9 ms | 69% / 4.4 ms | 35 | 4 | not tracked | 1.8% |
| 2 | Loudness fingerprint + nudge instead of mute | 89% / 1.7 ms | 87% / 2.0 ms | 6 | 0 | not tracked | 1.6% |
| 3 | Velocity tracker for clock drift | *100% / 0.0 ms (fake)* | *100% (fake)* | 4 | 0 | not tracked | 1.7% |
| 4 | Honest scoring, probes only outside band | **93% / 2.5 ms** | **91% / 2.4 ms** | 11 | 0 | 26–32% | 2.0% |
| 5 | Fingerprint rules out weak strays | (too few known) | (too few known) | 3 | 0 | 87% | 1.7% |
| 6 | Unknown only outside the in-time band | ~100% (mostly merged) | ~100% | 5 | 0 | 34% | 1.5% |
| 7 | Session-long reflection memory | ~100% (mostly merged) | ~100% | 5 | 0 | 65% | 1.4% |
| 8 | Inaudible nudges every 6 s | 88% / 2.1 ms | 84% / 3.0 ms | 8 | 0 | 38–40% | **1.3%** |

## What each round taught

1. **The CPU was in the bookkeeping, not the FFT.** A profile and an offline benchmark showed the FFT costs ~1 ms per reading. Most of the time went to sorting all 49k correlation values for a noise floor and to allocating ~2 MB of arrays per reading. Sampling every 8th value, scanning only ±350 ms while tracking, reusing buffers and measuring every 1.5 s once stable cut CPU 3.0% → 1.3% (−57%) with identical accuracy in the benchmark.
2. **Frequent probes had been hiding a mistaken-identity bug.** With both followers expected at 0 ms, a new spike went to a coin flip, so the wrong speaker got corrected. A per-speaker **loudness fingerprint** (spike height measured at lock-in, refined whenever identity is confirmed) fixed it.
3. **Muting to identify a speaker is audible; nudging isn't.** Sliding a candidate 6–10 ms and watching which spike moves identifies it with no dropout.
4. **The capture clock drifts against the mic** (~0.5 ms/s when a Bluetooth speaker is the clock). The anti-hijack slew limit couldn't follow it, so the tracker got stranded. An **α-β tracker** learns that velocity separately from the jump limit.
5. **I was grading my own homework wrong.** Unattributed readings were scored as 0 ms error. That made iteration 3 look perfect and fed fake perfect rounds to the self-tuner (its scores, drift rate and jitter had to be reset). Readings are now **assigned / merged / unknown**, and unknowns are never scored or learned from.
6. **Identity only matters outside the in-time band.** A stray 3 ms away is in time whoever owns it.
7. **Rooms have fixed reflections.** A spike that two nudges couldn't match is remembered as a reflection for the session.
8. **The remaining limit is physical.** With one mic, two speakers at similar loudness can't be told apart from a single reading, only by a nudge. The unknown rate followed fingerprint similarity, not the code: 26% when the fingerprints differed (0.64 vs 2.05), 65–87% when they matched (0.40 vs 0.35). Rounds 5–8 are kept because they are logically sound, but their measured differences are within the run-to-run noise from music and placement.

## Practical tips from this

- **Make the speakers sound different at the mic:** put the mic closer to one, or set them to clearly different volumes. Distinct fingerprints let SpeakerSync attribute almost every reading on the spot.
- Clear drums and steady volume give the strongest spikes. Quiet passages make SpeakerSync hold its last setting.

## Kept in the model (current `main.swift`)

Lean DSP · adaptive pace · loudness fingerprint (both directions) · nudge identification (every ≥6 s) · α-β reference tracker with loss recovery · honest assigned/merged/unknown accounting · band-limited probing · session reflection memory · the self-tuner, drift-rate learner and noise-band learner from v3.

## Next if needed

- A second mic, or the mic placed off-centre, would break the loudness symmetry for good.
- Score each change across several lock-ins (different fingerprints) before judging it. Single 6-minute runs are too noisy for effects under ~10%.

## Iteration 9 (evening): retuned for 3 outputs, buffer ratchet fixed

**What was broken (measured from the log and live status):**
- **Drift learner ran away:** the Eris at +0.60 ms/s and the JBL at −0.59 ms/s, both at the cap. Real Bluetooth clock drift is under ~0.15 ms/s.
- **One tuning profile per speaker** was shared by 2- and 3-speaker sessions, so they overwrote each other.
- **All followers explored settings at once**, so each was scored on the others' corrections.
- **"Merged" readings (assumed 0 ms) fed the noise learner**, which then believed the jitter was 0.7 ms and kept the in-time band at its 4 ms floor.
- **Buffers only ever grew (the "everything is half a second late" bug).** Wrong lock readings (e.g. "Eris −726 ms") were added to buffers and saved. The Brane ended with a 321 ms hold-back, the followers with 2–4 s buffers. Past ~1.36 s a follower re-snaps on every audio callback, and `snaps == aggSeq` confirmed that.

**Fixes (`main.swift`, iteration 8 kept as `main_v3_8.swift`):**
- Tuning is saved per set of outputs and drift per reference speaker. The old pinned drift values were discarded.
- Drift is learned only from same-direction corrections over at least 60 s, capped at ±0.15 ms/s. Identification nudges are excluded.
- One follower explores at a time while the others hold their best settings, rotating after each 100-reading round.
- Noise is learned only from attributed readings.
- Every lock starts from minimal buffers and rebuilds them from that lock's measured latencies. Impossible lock readings (latency outside 0–900 ms) are re-measured. Buffers are capped (hold-back 250 ms, followers 1.1 s), and a follower that would need more triggers a re-lock.

**Measured (5 min, 3 outputs, fresh tuning profile):**

| | Iteration 8 | Iteration 9 |
|---|---|---|
| Total delay (Mac → sound) | ~740 ms | **466 ms** (the Brane's own ~420 ms + 46 ms) |
| Eris in ±6 ms / mean error / p90 | 88% / 2.1 ms / 8.3 ms | 70% / 4.7 ms / **6.2 ms** |
| JBL in ±6 ms / mean error / p90 | 84% / 3.0 ms / 11.1 ms | 84% / 2.7 ms / **8.2 ms** |
| Unknown readings | 38–40% | **3–4%** |
| Follower snaps | every callback | 0 |

Read with care: the Eris's lower in-±6 ms figure is mostly the fresh profile's default ±7.5 ms band (errors of 6–7.5 ms are left alone); its p90 improved. Unknowns fell because the rebuilt buffers made the loudness fingerprints distinct (Eris 0.36, JBL 1.70). This was one 5-minute run, so it's noisy.

## Iteration 10 (late evening): SyncLab's sweep calibration merged into SpeakerSync

**Changes (`main.swift`, iteration 9 kept as `main_v3_9.swift`):**
- **The lock is now a sweep calibration.** A 0.4 s log sweep goes into the ring every 1.5 s, with only the output being measured unmuted and the music muted for ~7–12 s. It works with the music paused.
- **Re-calibration on events:** a stream interruption (callback gap > 0.25 s), a macOS latency-change notice, or a strong spike more than 25 ms off that no follower owns. That last one is the reference jumping, because nudges can't move the reference.
- **Pace:** every 0.75 s, then 1.5 s after 1 min in time, then 3 s after 5 min.
- **The loudness fingerprint is learned from music and kept per setup.** Sweep loudness ratios aren't comparable to music spikes.

**Measured:**
- **Calibration:** detection 91–374× noise (music locks gave 16–75×), no false locks, and 7–12 s for three speakers.
- **The Brane's own delay jumped ~420 → 564 ms after a lock.** The old tracker hid it: it latched onto the Eris+JBL spike and filed the real Brane spike (+130 ms) as a "reflection". The new far-spike rule caught a later jump (23:00:25) and re-calibrated automatically.
- **Steady-state tracking was worse in this run** (6 min, 3 outputs):

| | Iteration 9 | Iteration 10 |
|---|---|---|
| Eris in ±6 ms / mean / p90 | 70% / 4.7 / 6.2 ms | 51% / 8.0 / 17.7 ms |
| JBL in ±6 ms / mean / p90 | 84% / 2.7 / 8.2 ms | 69% / 5.5 / 13.8 ms |
| Corrections (Eris / JBL) | 1 / 4 | 24 / 18 |
| Unknown | 3–4% | 4% |
| CPU | 2.5% | 1.4% |

The corrections alternate in sign, which looks like hunting. The conditions differed: the Brane was jumping, at a 564 ms delay, and the tuning profile was fresh. A likely suspect is that a speaker's delay measured on a sweep differs from its delay on music (frequency-dependent DSP delay; the Eris showed 14–29 ms between bands in SyncLab), so tracking starts every calibration 10–20 ms off. Unproven. **Next:** an A/B run of iteration 9 vs 10 back to back.

**Also seen:** on 3 of the last 5 launches, macOS's tap didn't start for 45 s to 5 min because the Brane's Bluetooth stream started late. This predates iteration 10.

### A/B: iteration 9 vs 10 (23:05–23:30, same music and placement, 5 min each, order 9-10-9-10)

| Run | Eris in ±6 ms | JBL in ±6 ms | Corrections (log) | Re-calibrations | Fingerprint used (Eris / JBL) |
|---|---|---|---|---|---|
| 9 (1st) | 85% | 93% | 8 | – | 0.35 / 0.76 (music lock) |
| 10 (1st) | 74% | 96% | 11 | 2 | 3.00 / 3.00 (sweep, clamped) |
| 9 (2nd) | 100%* | 100%* | 0 | – | 0.81 / 1.02 (music lock) |
| 10 (2nd) | 46% | 62% | 55 | 1 | 1.53 / 3.00 (sweep) |

\* Every reading was "merged" (all spikes within ±2 ms), so this means in time but not individually verified.

**Iteration 9 won.** Iteration 10 hunts: corrections alternate sign every ~4 s, and the JBL's first readings flip between +13.5 and −13.5 ms. That's two followers' identities being swapped.

**Cause: fingerprints.** A sweep's correlation peak height is whitened (PHAT), so with a clean sweep every speaker scores near maximum and the loudness ratio clamps at 3.00. It says nothing about loudness. Music fingerprints should have been reused, but iteration 9 rewrote the memory files without the new `amps` field during the A/B, so iteration 10 fell back to the sweep ratios. That's a test artifact, but the same failure hits any brand-new setup.

**Sweep-vs-music timing offset:** it exists but is small. Right after a sweep calibration the JBL read +13.6 ms and the Eris −4.1 ms on music, then got corrected. It isn't the main cause.

**Speakers changing their own delay:** the far-spike re-calibration fired 3 times. The lock offsets show the **Eris** moving by +91 ms and +44 ms between calibrations while the JBL held, so it's not only the Brane that jumps.

## Iteration 11: music-measured loudness + speaker levels

**Changes:**
- **Lock = sweep for timing, then ~2 s of music per speaker alone for the loudness fingerprint** (a sweep can't give one). With no music it falls back to the saved fingerprint for that set of speakers, or a neutral one that it learns.
- **Levels:** each speaker's own hardware (Bluetooth absolute) volume is read every tick. The menu bar has a **Levels** slider per speaker that sets it. Any level change, from the menu or the speaker's buttons, rescales that speaker's fingerprint at once (amplitude ≈ level²). Tested: JBL 76 → 66 → 76% gave fingerprint 0.74 → 0.56 → 0.75 within one tick.
- **Bug:** these speakers report their volume in dB as ~0 dB at any level. The old `volumeGain()` trusted that and is removed.
- **False-alarm learning:** if a far-spike re-calibration finds no output moved more than 8 ms, that spike is learned as a room reflection.

**Measured (6 min, levels changed during the run):** Eris 57%, JBL 68% within ±6 ms, 21 corrections, 3 re-calibrations. One of the three was a false alarm (offsets moved ≤ 4 ms), which the false-alarm rule now handles.

**A measurement blind spot to fix before trusting any ranking.** The in-time figures only measure followers against the tracked reference spike. When the reference's delay jumps and the tracker latches onto the followers (what Vivaan heard at 22:55), the metric still reads ~100%. So iteration 9's 100%* A/B run can't be told apart from that failure. Iterations 10–11 detect and correct it, which costs re-calibrations and lowers their scores. **Next:** a ground-truth check of the reference, e.g. comparing each re-calibration's measured offsets with what the tracker believed, and Vivaan's ears.

## Iterations 12–13 (around midnight): level spotlight, live cadence, Eris as reference

**Iteration 12, level spotlight (Vivaan's idea):** when a spike has no owner, turn the other outputs down 3 dB one candidate at a time and see whose spike stands out. In a 6-minute run it caught one real Brane slip (+13.5 ms, stood out 52%) and re-locked only that speaker, with 4 corrections in total (followers read 100% in time).

**Iteration 13, live system:**
- A reading every **0.25 s** (was 0.75 s, slowing to 3 s when calm). The mic window is **0.75 s** while tracking (1.5 s for locks), the wait after a change is 1.5 s (was 2.3 s), and the system never slows down when calm.
- Nudges can repeat after 2 s (was 6 s).
- **Reference speaker** is now a menu choice: Automatic (slowest) or pin one. The reference hold-back cap went from 0.25 s to 1 s so a faster reference can wait. **The Eris is pinned** (it holds back ~424 ms for the Brane, total delay ~657 ms). The Brane, whose own delay jumps, is now a follower, so the inaudible nudge can identify it.
- **Test hook:** `http://localhost:8765/slip?i=<index>&ms=<shift>` moves an output without telling the tracker. `bench/slip.py` times the response.

**Slip test (iteration 13 with the spotlight on):**

| Slip | First sign | First correction |
|---|---|---|
| JBL +15 ms | 0.8 s | none in 25 s |
| Brane +40 ms | 9.1 s | 27 s (nudge identified it) |
| Eris (ref) +20 ms | 0.0 s | 20 s (wrong re-anchor, −57 ms) |
| JBL −8 ms | 0.0 s | 7.7 s |

Detection is now near-instant. **Identification is the bottleneck, and the level spotlight was the problem.** A 3 dB dip changes a spike's height by ~30%, but heights swing 0.3–2× between readings with the music. So it named the wrong owner (moved the JBL 59 ms for what was probably the Brane) and dismissed the Brane's real +100–135 ms spikes as reflections three times. **The spotlight's decisions are now disabled** (the code stays behind `useSpotlight`). Timing nudges identify followers reliably, and a far unowned spike goes to a sweep re-calibration.

**Not yet re-tested:** the slip test with the spotlight off. The capture didn't start (8+ min `w = 0`, probably no music playing at ~00:05).

### Slip test with the spotlight off, Eris as reference (00:09, 2026-11-15)

| Slip | First sign | First correction | Back in time |
|---|---|---|---|
| JBL +15 ms | 1.0 s | **2.5 s** (measured 14.9 ms) | 23.5 s |
| Brane +40 ms | 1.9 s | sweep re-calibration at 8 s (the nudge didn't claim it) | after ~20 s |
| Eris (reference) +20 ms | 1.8 s | **2.5 s** | **8.2 s** |
| JBL −8 ms | 0.5 s | interrupted by a re-calibration | — |

This is a big improvement on the spotlight run (8–27 s or never). **Still open:**
- **Brane slips aren't claimed by the nudge**, so they fall back to a full re-calibration (~20 s of muted music).
- **At the 0.25 s cadence the JBL gets corrected every 2–4 s in alternating directions (±6 ms).** The shorter 0.75 s window is noisier, and the decision window (3 readings) now spans only 0.75 s of time. Next: keep the cadence but require the same sign over ~1.5 s, or raise the floor of the in-time band.

## Live dashboard redesign (2026-11-15)

Re-dealt with the taste skill: **soot-pale-lime + Familjen Grotesk / IBM Plex Mono**, sharp corners (was graphite-safety-orange / Host Grotesk). It shows the new system:
- **Header:** the reference speaker (pinned or automatic), total delay, the reading cadence, and % in time over the last 60 s.
- **Controls:** Re-calibrate, and a **Test slip** control (any speaker, ±15 ms) wired to `/slip`.
- **"Where each speaker lands":** a live lane of every speaker against the reference, with the in-time band.
- **Speaker cards:** role, offset, the speaker's **own Bluetooth delay**, buffer or hold-back, hardware **level**, **loudness fingerprint**, learned drift, corrections and tuning.
- **Charts:** timing over 3 minutes (identified vs merged readings, corrections marked) and the mic correlation with spikes.
- **Calibration pipeline:** Sweep → Loudness → Buffers → Live, with the per-speaker step running now.
- **"What the system just did":** a feed of re-calibrations and their reasons, nudge identifications, corrections, level changes, test slips and learned reflections.

`status.json` gained `latencyMs` per device, `totalDelayMs`, `referencePinned` and `lockedAt`. `/log` now returns 160 lines. The canvas self-growing bug from the first dashboard reappeared and is fixed the same way (`data-h`).

## Iteration 14: same-side rule (2026-11-15, 00:19)

- **Change:** small errors are corrected only when every reading for ~1.5 s sits on the same side, at least half the band out. Jumps over 25 ms are corrected after 3 matching readings (0.75 s).
- **Result:** the JBL hunting is gone. It went from 13 corrections and 4 direction flips in 75 s to 4 corrections and 1 flip in 5 min.
- **Cost:** CPU averaged **9.9%** at the 0.25 s cadence (was ~1.4–3% at 0.75 s). This needs addressing.
- The slip test was spoiled by two sweep re-calibrations firing during it.

## Iterations 15–16: quiet re-lock, no sweep after first pairing (2026-11-15, 00:27–00:41)

**Goal (Vivaan):** the sweep only when a speaker is first paired; account for drift without it afterwards.

**Built:**
- Each speaker's own delay is saved after every sweep and quiet re-lock.
- A launch starts from the saved delays.
- Each speaker is located in the music by sliding it 10 ms (slowly, inaudible). The **reference is slid too**, through a new slewed reference nudge.
- Launch, stream drops, macOS delay changes, unowned spikes and buffer-floor hits all start a **quiet re-lock**, not a sweep. The sweep runs only for a speaker with no saved delay, on the Re-calibrate button, or as a fallback.
- **Slides go 10 ms *earlier*, not later.** The room's reflections sit 10–30 ms after each spike and hid a later copy.
- A shift every speaker shares only re-anchors the tracker. Only movement *relative to the reference* changes buffers, and a relative move over 20 ms must be seen twice within 3 ms. Sightings are combined over up to 4 passes.

**Measured:**
- **A real Brane jump (~400 → ~555 ms) was caught by the nudge and fixed with no sweep** (00:29:19).
- Positions are very repeatable when found: the Brane read −12.0 / −11.9 ms, −93.9 / −93.8 ms and +107.6 / +107.2 / +107.3 ms across passes.
- **Every launch shifts the whole measuring frame by ~100 ms** (everyone reads +100 or −120 ms together). This is the mic-to-capture timing, not the speakers.
- **Three launches: 1 quiet re-lock succeeded** (corrected a 99 ms relative error in ~50 s with no sweep). **2 fell back to the sweep** after ~70–80 s.
  - **Eris (reference):** found in only ~25% of passes.
  - **Brane:** its own delay keeps jumping in the first ~30 s after a stream starts (−26 → +124 ms within 17 s), so a launch-time scan chases a moving target.

**Verdict:** quiet correction *during* listening works (nudges for followers, a re-anchor for frame shifts). At *launch* it's currently worse than an immediate sweep: about a minute of trying, and two thirds of the time the sweep runs anyway. Options in the open issues.

## Iteration 17: sweep at launch, quiet during listening (2026-11-15, 00:43)

**Decision (Vivaan):** sweep at launch only.
- A launch restarts every Bluetooth stream, which is what moves the delays.
- **Sweep:** at app launch, when the set of speakers changes, and on the Re-calibrate button.
- **Quiet re-lock** (10 ms slides, nothing muted): every event during listening (stream drop, macOS delay change, unowned spike, buffer floor).
- `quietStart()` is kept for a later sweep-free launch attempt. Iteration 16 is backed up as `main_v3_16.swift`.

**Verified:** launch → sweep → locked. In the same minute the Eris disconnected and a new **JBL Charge 6** was added. SpeakerSync re-swept and locked the Brane, JBL Clip 5 and Charge 6 (Charge 6 own delay ~450 ms) 14 s after audio started. With the pinned Eris absent, the Brane acts as reference until the Eris returns. The dashboard now gives the Charge 6 its own colour.

## Iteration 18: no false "in time" without the reference (2026-11-15, 00:53)

**Vivaan:** "not synced but reading as locked".
- At 00:52:15 the Eris (reference) went 72% → 0% volume. An old rule muted every follower whenever the reference was muted or at 0%.
- With no reference spike, every reading counted as "merged = in time", so the dashboard said locked while the mic couldn't hear the reference at all.
- The 00:50 quiet re-lock also accepted an impossible sighting: the Brane with its own delay at −8 ms.
- **Confirmed the Bluetooth limit:** when the Eris reconnected, the JBL Clip 5 dropped. **This MacBook Air streams to 3 Bluetooth speakers at most.**

**Fixes:**
- A reference at 0% no longer silences the others.
- **If the reference's own spike isn't heard, the status says "timing unverified"** (or that the reference is at 0%) and nothing is scored as in time.
- The tracker never re-anchors on the strongest spike any more (that latch caused both "locked but out of sync" incidents). It starts a quiet re-lock that nudges the reference instead.
- Quiet re-lock sightings must be a real delay (20–900 ms).

**State after the rebuild:** sweep-locked with the Brane, Eris (reference) and Charge 6. All levels are ~25%, so the Brane was heard at only 9× the noise floor. Lower volume means weaker spikes and slower identification.

## Iteration 19: corrections that actually catch up (2026-11-15, morning)

**Vivaan:** "when the songs go out of sync the system does not nudge them back effectively at all". From the Brane + Eris session log (08:35–08:36):
1. The Brane jumped +109 ms. It was caught in ~1 s, but as the slowest speaker it sat on its 93 ms minimum buffer, with only ~23 ms of room to play earlier. So the app jumped the **Eris (reference) 138 ms** instead (an audible lurch), lost the reference, and needed a 25 s quiet re-lock.
2. Afterwards the Brane crept ~1 ms/s later. Corrections fixed only **40%** of each error and came ~3 s apart, so the error grew (6 → 10 → 13 → 25 ms) until the Eris was jumped again (+72 ms).
3. The drift learner needed 60 s of same-direction corrections, so it never kicked in.

**Fixes:**
- Follower headroom raised from 93 to **200 ms**. A follower can now be moved ~130 ms earlier without touching the reference. Cost: ~100 ms more total delay.
- Confirmed errors are corrected at **≥ 85%** (was 40–70%).
- Drift is learned after **20 s** of consistent corrections (was 60 s).

**Not measured:** Vivaan asked for no testing while playing music.
