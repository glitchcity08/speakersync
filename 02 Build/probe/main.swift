// SyncProbe — one-off test: can each speaker be identified by (1) an ultrasonic tone or (2) a quiet watermark code?
// Builds on src/Shared (AudioDevices.swift, Watermark.swift), the same modules SpeakerSync can adopt.
// Writes ~/.local/speakersync/probe/results.txt and schedule.txt, then quits.
import Foundation
import CoreAudio
import AVFoundation
import AppKit
import Accelerate

let outDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/speakersync/probe")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var report = ""
func say(_ s: String) { report += s + "\n"; try? report.write(to: outDir.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8) }

// MARK: outputs = SpeakerSync's chosen outputs
struct Cfg: Decodable { let outputs: [String] }
let cfg = (try? JSONDecoder().decode(Cfg.self, from: Data(contentsOf: outDir.deletingLastPathComponent().appendingPathComponent("config.json"))))?.outputs ?? []
let outs = cfg.compactMap { SSAudio.device(uid: $0) }.filter { SSAudio.hasOutput($0.id) }
let short = { (n: String) in n.replacingOccurrences(of: #"-\d{6,}$"#, with: "", options: .regularExpression) }
let ins = SSAudio.devices().filter { SSAudio.hasInput($0.id) }
guard outs.count >= 2, let mic = ins.first(where: { $0.name.contains("MacBook") }) ?? ins.first else { say("need 2+ outputs and a mic"); exit(1) }
let fs = 44100.0
for o in outs where SSAudio.sampleRate(o.id) != fs { SSAudio.setSampleRate(o.id, fs) }
let micSR = SSAudio.sampleRate(mic.id)

// MARK: schedule (one output sounds at a time)
// run 2: quieter. Tones: 3 frequencies × 3 levels; watermark codes well below the first run's −55 dB.
let tones: [Double] = [19000, 20000, 21000]
let toneLevels: [Double] = [-30, -40, -50]               // tone peak level, dBFS
let levels: [Double] = []                                // watermark codes skipped in run 2: maths shows a 2 s code must sit within ~30 dB of the music to be found, which you can hear
let toneLen = Int(0.6 * fs), toneGap = Int(1.6 * fs), pnLen = Int(2.0 * fs), pnGap = Int(1.4 * fs)
let maxDelay = 2.5                                       // s: Bluetooth latency + stream start can exceed 1 s
struct Seg { let out: Int; let kind: String; let value: Double; let level: Double; let start: Int; let len: Int }
var segs: [Seg] = [], cursor = Int(1.0 * fs)
for (k, _) in outs.enumerated() { for l in toneLevels { for f in tones { segs.append(Seg(out: k, kind: "tone", value: f, level: l, start: cursor, len: toneLen)); cursor += toneLen + toneGap } } }
for (k, _) in outs.enumerated() { for l in levels { segs.append(Seg(out: k, kind: "code", value: l, level: l, start: cursor, len: pnLen)); cursor += pnLen + pnGap } }
let total = cursor + Int(1.5 * fs)
let codes = outs.indices.map { WatermarkCode(seed: UInt64(1000 + $0), length: pnLen) }
var buffers = outs.map { _ in [Float](repeating: 0, count: total) }
for s in segs {
    for i in 0..<s.len {
        let fade = Float(min(1, Double(min(i, s.len - 1 - i)) / (0.01 * fs)))
        let v: Float = s.kind == "tone" ? Float(pow(10, s.level / 20)) * fade * Float(sin(2 * Double.pi * s.value * Double(i) / fs))
                                        : Float(pow(10, s.value / 20)) * fade * codes[s.out].samples[i]
        buffers[s.out][s.start + i] = v
    }
}
var sched = "SyncProbe schedule (seconds from start)\n"
for s in segs { sched += String(format: "%6.1f s  %@  %@\n", Double(s.start) / fs, short(outs[s.out].name), s.kind == "tone" ? String(format: "%.0f kHz tone at %.0f dBFS", s.value / 1000, s.level) : String(format: "watermark %.0f dBFS", s.value)) }
try? sched.write(to: outDir.appendingPathComponent("schedule.txt"), atomically: true, encoding: .utf8)

// MARK: audio
final class Box { var pos = 0; var host0: UInt64 = 0; var proc: AudioDeviceIOProcID? }
let boxes = outs.map { _ in Box() }
let micCap = Int(micSR * (Double(total) / fs + 10))
let micBuf = UnsafeMutablePointer<Float>.allocate(capacity: micCap); micBuf.initialize(repeating: 0, count: micCap)
var micN = 0, micHost0: UInt64 = 0, micProc: AudioDeviceIOProcID?

func run() {
    AudioDeviceCreateIOProcIDWithBlock(&micProc, mic.id, nil) { _, inp, inTime, _, _ in
        let l = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inp))
        guard let b = l.first, b.mNumberChannels > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { return }
        if micHost0 == 0 { micHost0 = inTime.pointee.mHostTime }
        let ch = Int(b.mNumberChannels), n = Int(b.mDataByteSize) / 4 / ch
        for i in 0..<n where micN < micCap { micBuf[micN] = d[i * ch]; micN += 1 }
    }
    AudioDeviceStart(mic.id, micProc)
    Thread.sleep(forTimeInterval: 0.5)
    for (k, o) in outs.enumerated() {
        let bx = boxes[k], buf = buffers[k]
        AudioDeviceCreateIOProcIDWithBlock(&bx.proc, o.id, nil) { now, _, _, out, _ in
            let l = UnsafeMutableAudioBufferListPointer(out), n = SSAudio.frames(l)
            if bx.host0 == 0 { bx.host0 = now.pointee.mHostTime }
            SSAudio.write(l, frames: n) { i in let p = bx.pos + i; let v = p < buf.count ? buf[p] : 0; return (v, v) }
            bx.pos += n
        }
        AudioDeviceStart(o.id, bx.proc)
    }
    say("SyncProbe: \(outs.map { short($0.name) }.joined(separator: ", ")) · mic \(mic.name) \(Int(micSR)) Hz · \(String(format: "%.0f", Double(total) / fs)) s")
    Thread.sleep(forTimeInterval: Double(total) / fs + 2)
    for (k, o) in outs.enumerated() { AudioDeviceStop(o.id, boxes[k].proc); AudioDeviceDestroyIOProcID(o.id, boxes[k].proc!) }
    AudioDeviceStop(mic.id, micProc); AudioDeviceDestroyIOProcID(mic.id, micProc!)
    FileManager.default.createFile(atPath: outDir.appendingPathComponent("mic.raw").path, contents: Data(bytes: micBuf, count: micN * 4))
    let meta: [String: Any] = ["micSR": micSR, "micHost0": micHost0, "outHost0": boxes.map { $0.host0 }, "outputs": outs.map { $0.uid }, "tick": SSAudio.hostTicksToSeconds]
    try? JSONSerialization.data(withJSONObject: meta).write(to: outDir.appendingPathComponent("meta.json"))
    analyse()
}

// MARK: analysis
func micIndex(_ k: Int, _ i: Int) -> Double { (Double(boxes[k].host0) - Double(micHost0)) * SSAudio.hostTicksToSeconds * micSR + Double(i) / fs * micSR }
func analyse() {
    let mbuf = UnsafeBufferPointer(start: micBuf, count: micN)
    say("\n== 1. Ultrasonic tones: how far above the room each tone arrives at the mic (dB; ≥ 10 dB = usable)")
    for lv in toneLevels {
        say(String(format: "   at %.0f dBFS", lv) + "".padding(toLength: 4, withPad: " ", startingAt: 0) + tones.map { String(format: "%7.0fk", $0 / 1000) }.joined())
        for k in outs.indices {
            var row = "     " + short(outs[k].name).padding(toLength: 14, withPad: " ", startingAt: 0)
            for s in segs where s.out == k && s.kind == "tone" && s.level == lv {
                let a = Int(micIndex(k, s.start)), frame = Int(0.02 * micSR)
                func pw(_ from: Int, _ to: Int) -> [Double] { stride(from: max(0, from), to: min(micN - frame, to), by: frame).map { SSDSP.goertzelPower(UnsafeBufferPointer(rebasing: mbuf[$0..<($0 + frame)]), freq: s.value, sampleRate: micSR) } }
                let on = pw(a, a + Int((0.6 + maxDelay) * micSR)).max() ?? 0
                let base = pw(a - Int(0.5 * micSR), a).sorted(); let b = base.isEmpty ? 1e-20 : base[base.count / 2]
                row += String(format: "%8.1f", 10 * log10(max(on, 1e-20) / max(b, 1e-20)))
            }
            say(row)
        }
    }
    let C = SSCorrelator(log2n: 18), recLen = pnLen + Int(maxDelay * fs)
    say("\n== 2. Watermark codes: detection strength at the mic (× noise; pure noise reaches ~7×, so ≥ 10 = a real detection)")
    say("   own code = this output's code found in its own window; worst other = strongest wrong code in that window (should stay low)")
    say("   " + "output".padding(toLength: 14, withPad: " ", startingAt: 0) + levels.map { String(format: "%11.0f dB", $0) }.joined())
    var latencies: [String] = []
    for k in outs.indices {
        var row = "   " + short(outs[k].name).padding(toLength: 14, withPad: " ", startingAt: 0); var lag = 0
        for s in segs where s.out == k && s.kind == "code" {
            let rec = SSDSP.resample(mbuf, start: micIndex(k, s.start), from: micSR, to: fs, count: recLen)
            let own = SSCorrelator.peak(C.correlate(code: codes[k].samples, recording: rec, sampleRate: fs, maxLag: Int(maxDelay * fs)))
            let other = outs.indices.filter { $0 != k }.map { SSCorrelator.peak(C.correlate(code: codes[$0].samples, recording: rec, sampleRate: fs, maxLag: Int(maxDelay * fs))).ratio }.max() ?? 0
            row += String(format: "  %5.1f/%-5.1f", own.ratio, other); lag = own.lag
        }
        latencies.append(String(format: "%@ %.0f ms", short(outs[k].name), Double(lag) / fs * 1000))
        say(row)
    }
    say("\n   (own/worst-other). Delay each code arrived with at the loudest level: " + latencies.joined(separator: ", "))
    var rms: Float = 0; vDSP_rmsqv(micBuf, 1, &rms, vDSP_Length(micN))
    say(String(format: "   room level at the mic during the test: %.0f dBFS", 20 * log10(max(rms, 1e-9))))
    say("\ndone")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
AVCaptureDevice.requestAccess(for: .audio) { ok in
    guard ok else { say("microphone permission denied"); exit(1) }
    DispatchQueue.global().async { run() }
}
app.run()
