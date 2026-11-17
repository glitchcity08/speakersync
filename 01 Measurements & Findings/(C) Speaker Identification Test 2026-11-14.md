# Speaker identification test: ultrasonic vs hidden codes (2026-11-14)

**Question:** can each speaker carry its own signal that the mic picks up but people don't hear, so SpeakerSync always knows which spike is which speaker?

**Tool:** SyncProbe (`02 Build/probe/`), built on the shared modules `02 Build/src/Shared/AudioDevices.swift` and `Watermark.swift` so SpeakerSync can adopt them directly. Speakers: Brane and Eris 4.5BT (the JBL was disconnected). Mic: MacBook Air, room level about −21 dBFS with music playing.

## Result 1: ultrasonic tones work

How far above the room each tone arrived at the mic (dB; 10+ = usable):

| Level | Brane 19 / 20 / 21 kHz | Eris 19 / 20 / 21 kHz | Heard by Vivaan? |
|---|---|---|---|
| −14 dBFS (run 1) | 20 / 20 / 11 | 45 / 44 / 44 | yes |
| −30 dBFS | 26 / 21 / 21 | 29 / 32 / 35 | **yes** |
| −40 dBFS | 18 / 18 / 26 | 21 / 25 / 19 | no |
| −50 dBFS | 15 / 15 / 23 | 16 / 15 / 13 | no |

- Bluetooth (both speakers) passes 19–21 kHz. Earlier I expected the codecs to cut it; they don't here.
- Music has almost no energy above 19 kHz, so the ultrasonic band is nearly silent and very quiet signals stand out.
- **Operating point: about −50 dBFS.** That's 20 dB under audible for Vivaan, with 13–23 dB detection margin.

## Result 2: a hidden code under the music doesn't work

- Run 1 was invalid: the analysis only searched up to 1 s of delay, and the codes arrived later.
- A synthetic check then showed that whitened correlation (PHAT-β, ideal for the music itself) destroys a buried code's gain, so buried codes need **plain correlation**. Even then, a 2 s code is only detectable within **~30 dB of the music**, and Vivaan heard every level from −55 dBFS up. Detectable and inaudible don't overlap. Making it work would need psychoacoustic shaping plus ~10 s of averaging.
- Fixed in `Watermark.swift`: `correlate` now defaults to plain correlation over 300 Hz–20 kHz, with a comment explaining why.

## Recommended design (not built yet)

Give each speaker its own quiet **code in its own ultrasonic lane** (e.g. Brane 19–20 kHz, Eris 20–21 kHz, JBL 21–22 kHz) at about −50 dBFS, and correlate the mic against each code. That gives:
- **identity** from the lane, independent of loudness, with no nudges or unknown readings;
- **timing** from the code's correlation peak, measured per speaker every reading;
- **no interference** from the music.

**Caveats to check:** each speaker's own high-frequency response (the Brane rolls off more than the Eris); people with sharper high-frequency hearing (younger guests); and **dogs and cats hear 19–22 kHz easily**, so it shouldn't run around pets.
