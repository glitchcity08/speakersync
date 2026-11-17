// SyncLab: experiments for the layered sync design ("00 Ideas & Features/(C) Layered Sync Design.md").
//   SyncLab calibrate            each output alone, 8 reps of an audible sweep + an inaudible ultrasonic code;
//                                the stream is restarted before reps 3 and 6 (does latency change per stream start?)
//   SyncLab openloop <minutes>   all outputs together, NO corrections; each repeats its own ultrasonic code once a
//                                second in its own slot; every callback timestamp and device event is logged
//   SyncLab analyse <run dir>    re-run the analysis on a saved run
// Builds on src/Shared (SSAudio, SSCorrelator, SSDSP). Outputs = SpeakerSync's chosen outputs (config.json), first = reference.
// Runs land in ~/.local/speakersync/lab/<mode>-<time>/ (raw data + report.txt).
import Foundation
import CoreAudio
import AVFoundation
import AppKit
import Accelerate

let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") }
let mode = args.first ?? "calibrate"
let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/speakersync")
let tick = SSAudio.hostTicksToSeconds
let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
let runDir: URL = mode == "analyse" && args.count > 1 ? URL(fileURLWithPath: args[args.index(after: args.startIndex)]) : home.appendingPathComponent("lab/\(mode)-\(stamp)")
try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
var report = ""
func say(_ s: String) { report += s + "\n"; try? report.write(to: runDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8) }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }

// MARK: - test signals
let codeLen = 0.1, ultraBand = (18500.0, 21500.0), sweepBand = (150.0, 14000.0)
/// Inaudible code: 201 random-phase sines from 19 to 21 kHz (100 ms, distinct per seed), peak-normalised.
func ultraCode(seed: UInt64, fs: Double, peakDB: Double) -> [Float] {
    var s = seed &* 0x9E3779B97F4A7C15 | 1
    func rnd() -> Double { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Double(s >> 11) / Double(1 << 53) }
    let n = Int(codeLen * fs); var x = [Double](repeating: 0, count: n)
    var f = 19000.0
    while f <= 21000 { let ph = 2 * Double.pi * rnd(), w = 2 * Double.pi * f / fs; for i in 0..<n { x[i] += sin(w * Double(i) + ph) }; f += 10 }
    return shape(x, fs: fs, peakDB: peakDB)
}
/// Audible calibration sweep: 0.5 s log sweep 200 Hz to 12 kHz.
func sweep(fs: Double, peakDB: Double) -> [Float] {
    let T = 0.5, n = Int(T * fs), f0 = 200.0, f1 = 12000.0, k = log(f1 / f0)
    return shape((0..<n).map { i in sin(2 * Double.pi * f0 * T / k * (exp(Double(i) / fs / T * k) - 1)) }, fs: fs, peakDB: peakDB)
}
func shape(_ x: [Double], fs: Double, peakDB: Double) -> [Float] {
    let fade = Int(0.005 * fs), n = x.count, peak = x.map { abs($0) }.max() ?? 1, g = pow(10, peakDB / 20) / peak
    return (0..<n).map { i in let e = min(1, Double(min(i, n - 1 - i)) / Double(fade)); return Float(x[i] * g * (0.5 - 0.5 * cos(Double.pi * e))) }
}

// MARK: - recorded data
struct CB { var pos: Int64; var outHost: UInt64; var sampleTime: Double; var rate: Double; var frames: Int32; var flags: UInt32; var now: UInt64 }
struct MCB { var pos: Int64; var host: UInt64; var sampleTime: Double }
struct Em: Codable { var pos: Int64; var kind: Int; var rep: Int; var seg: Int }   // kind 0 = sweep, 1 = ultrasonic code
struct Ev: Codable { var t: Double; var dev: String; var what: String; var value: Double }
struct Meta: Codable { var mode: String; var fs: Double; var micSR: Double; var names: [String]; var uids: [String]; var emissions: [[Em]]; var seconds: Double; var codeDB: Double; var sweepDB: Double; var micName: String }

func saveBin<T>(_ p: UnsafePointer<T>, _ n: Int, _ name: String) { try? Data(bytes: p, count: n * MemoryLayout<T>.stride).write(to: runDir.appendingPathComponent(name)) }
func loadBin<T>(_ name: String, _: T.Type) -> [T] {
    guard let d = try? Data(contentsOf: runDir.appendingPathComponent(name)) else { return [] }
    return d.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
}

// MARK: - recording run
final class OutBox {
    let dev: SSDevice, sweepSig: [Float], codeSig: [Float], cap = 800_000
    let cbs: UnsafeMutablePointer<CB>
    var pos: Int64 = 0, nCB = 0, proc: AudioDeviceIOProcID?
    var periodic = false, period: Int64 = 0, phase: Int64 = 0
    var sweepAt: Int64 = -1, codeAt: Int64 = -1
    init(_ d: SSDevice, sweep: [Float], code: [Float]) { dev = d; sweepSig = sweep; codeSig = code; cbs = .allocate(capacity: cap) }
}

func record() {
    struct Cfg: Decodable { let outputs: [String] }
    let uids = (try? JSONDecoder().decode(Cfg.self, from: Data(contentsOf: home.appendingPathComponent("config.json"))))?.outputs ?? []
    let outs = uids.compactMap { SSAudio.device(uid: $0) }.filter { SSAudio.hasOutput($0.id) }
    let ins = SSAudio.devices().filter { SSAudio.hasInput($0.id) }
    guard outs.count >= 2, let mic = ins.first(where: { $0.name.contains("MacBook") }) ?? ins.first else { say("need 2+ connected outputs and a mic"); exit(1) }
    let fs = 44100.0
    for o in outs where SSAudio.sampleRate(o.id) != fs { SSAudio.setSampleRate(o.id, fs) }
    let micSR = SSAudio.sampleRate(mic.id)
    let codeDB = -40.0, sweepDB = -20.0
    let boxes = outs.enumerated().map { OutBox($0.element, sweep: sweep(fs: fs, peakDB: sweepDB), code: ultraCode(seed: UInt64(7001 + $0.offset), fs: fs, peakDB: codeDB)) }
    let minutes = mode == "openloop" ? (args.count > 1 ? Double(args[args.index(after: args.startIndex)]) ?? 30 : 30) : 4
    let micCap = Int(micSR * (minutes * 60 + 60))
    let micBuf = UnsafeMutablePointer<Float>.allocate(capacity: micCap); micBuf.initialize(repeating: 0, count: micCap)
    let mcbs = UnsafeMutablePointer<MCB>.allocate(capacity: 900_000)
    var micN = 0, nM = 0, micProc: AudioDeviceIOProcID?
    var events: [Ev] = [], emissions = outs.map { _ in [Em]() }
    let evLock = NSLock(), t0 = Double(mach_absolute_time()) * tick

    // device events (layer 3 candidates)
    let sels: [(AudioObjectPropertySelector, AudioObjectPropertyScope, String)] = [
        (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, "alive"),
        (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, "sampleRate"),
        (kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, "latency"),
        (kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, "safetyOffset"),
        (kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal, "overload"),
        (kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, "bufferSize"),
        (kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, "runningSomewhere"),
        (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, "streams"),
        (kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, "dataSource")]
    for d in outs + [mic] {
        for (sel, sc, what) in sels {
            var a = SSAudio.address(sel, sc)
            guard AudioObjectHasProperty(d.id, &a) else { continue }
            AudioObjectAddPropertyListenerBlock(d.id, &a, DispatchQueue.global()) { _, _ in
                var v = 0.0
                if sel == kAudioDevicePropertyNominalSampleRate { v = SSAudio.sampleRate(d.id) } else if sel != kAudioDeviceProcessorOverload && sel != kAudioDevicePropertyStreamConfiguration { v = Double(SSAudio.uint32(d.id, sel, sc)) }
                evLock.lock(); events.append(Ev(t: Double(mach_absolute_time()) * tick, dev: d.name, what: what, value: v)); evLock.unlock()
            }
        }
    }

    AudioDeviceCreateIOProcIDWithBlock(&micProc, mic.id, nil) { _, inp, inTime, _, _ in
        let l = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inp))
        guard let b = l.first, b.mNumberChannels > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { return }
        let ch = Int(b.mNumberChannels), n = Int(b.mDataByteSize) / 4 / ch
        if nM < 900_000 { mcbs[nM] = MCB(pos: Int64(micN), host: inTime.pointee.mHostTime, sampleTime: inTime.pointee.mSampleTime); nM += 1 }
        for i in 0..<n where micN < micCap { micBuf[micN] = d[i * ch]; micN += 1 }
    }
    AudioDeviceStart(mic.id, micProc)
    Thread.sleep(forTimeInterval: 0.5)
    func makeProc(_ b: OutBox) {
        AudioDeviceCreateIOProcIDWithBlock(&b.proc, b.dev.id, nil) { now, _, _, out, outTime in
            let l = UnsafeMutableAudioBufferListPointer(out), n = SSAudio.frames(l)
            let ts = outTime.pointee
            if b.nCB < b.cap { b.cbs[b.nCB] = CB(pos: b.pos, outHost: ts.mHostTime, sampleTime: ts.mSampleTime, rate: ts.mRateScalar, frames: Int32(n), flags: ts.mFlags.rawValue, now: now.pointee.mHostTime); b.nCB += 1 }
            let p0 = b.pos, sa = b.sweepAt, ca = b.codeAt, per = b.periodic, P = b.period, ph = b.phase
            SSAudio.write(l, frames: n) { i in
                let p = p0 + Int64(i); var v: Float = 0
                if per { let m = Int(((p - ph) % P + P) % P); if m < b.codeSig.count { v = b.codeSig[m] } }
                if sa >= 0 { let m = Int(p - sa); if m >= 0 && m < b.sweepSig.count { v += b.sweepSig[m] } }
                if ca >= 0 { let m = Int(p - ca); if m >= 0 && m < b.codeSig.count { v += b.codeSig[m] } }
                return (v, v)
            }
            b.pos += Int64(n)
        }
    }
    for b in boxes { makeProc(b) }
    say("SyncLab \(mode) · \(outs.map { $0.name }.joined(separator: ", ")) · mic \(mic.name) \(Int(micSR)) Hz · reference \(outs[0].name)")

    if mode == "openloop" {
        for (k, b) in boxes.enumerated() { b.period = Int64(fs); b.phase = Int64(0.5 * fs) + Int64(k) * Int64(fs) / Int64(boxes.count); b.periodic = true }
        for b in boxes { AudioDeviceStart(b.dev.id, b.proc) }
        say("open loop for \(Int(minutes)) min: inaudible codes, no corrections")
        let end = Date().addingTimeInterval(minutes * 60)
        while Date() < end { Thread.sleep(forTimeInterval: 60); say("  … \(Int((minutes * 60 - end.timeIntervalSinceNow) / 60)) min") }
        for (k, b) in boxes.enumerated() { var p = b.phase; while p + Int64(codeLen * fs) < b.pos { emissions[k].append(Em(pos: p, kind: 1, rep: 0, seg: 0)); p += b.period } }
    } else {
        for b in boxes { AudioDeviceStart(b.dev.id, b.proc) }
        Thread.sleep(forTimeInterval: 2)
        for (k, b) in boxes.enumerated() {
            say("calibrating \(b.dev.name)")
            var seg = 0
            for rep in 0..<8 {
                if rep == 3 || rep == 6 {   // stream restart: stop, wait 3 s, start, let Bluetooth settle
                    AudioDeviceStop(b.dev.id, b.proc); Thread.sleep(forTimeInterval: 3); AudioDeviceStart(b.dev.id, b.proc); Thread.sleep(forTimeInterval: 2); seg += 1
                }
                let p = b.pos + Int64(0.3 * fs), q = p + Int64(0.9 * fs)
                b.codeAt = q; b.sweepAt = p
                emissions[k].append(Em(pos: p, kind: 0, rep: rep, seg: seg)); emissions[k].append(Em(pos: q, kind: 1, rep: rep, seg: seg))
                Thread.sleep(forTimeInterval: 2.6)
            }
            b.sweepAt = -1; b.codeAt = -1
        }
    }
    for b in boxes { AudioDeviceStop(b.dev.id, b.proc); AudioDeviceDestroyIOProcID(b.dev.id, b.proc!) }
    AudioDeviceStop(mic.id, micProc); AudioDeviceDestroyIOProcID(mic.id, micProc!)

    // save raw data
    for (k, b) in boxes.enumerated() { saveBin(b.cbs, b.nCB, "out\(k).bin") }
    saveBin(mcbs, nM, "mic_cb.bin")
    var i16 = [Int16](repeating: 0, count: micN)
    for i in 0..<micN { i16[i] = Int16(max(-32767, min(32767, micBuf[i] * 32767))) }
    i16.withUnsafeBufferPointer { saveBin($0.baseAddress!, micN, "mic.i16") }
    evLock.lock(); let evs = events.map { Ev(t: $0.t - t0, dev: $0.dev, what: $0.what, value: $0.value) }; evLock.unlock()
    try? JSONEncoder().encode(evs).write(to: runDir.appendingPathComponent("events.json"))
    let meta = Meta(mode: mode, fs: fs, micSR: micSR, names: outs.map { $0.name }, uids: outs.map { $0.uid }, emissions: emissions, seconds: Double(micN) / micSR, codeDB: codeDB, sweepDB: sweepDB, micName: mic.name)
    try? JSONEncoder().encode(meta).write(to: runDir.appendingPathComponent("meta.json"))
    say("saved to \(runDir.path)\n")
    analyse()
}

// MARK: - analysis
func median(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.sorted()[x.count / 2] }
func slopePerMin(_ t: [Double], _ y: [Double]) -> Double {   // Theil–Sen on a subsample: robust to jumps and outliers
    let idx = Array(stride(from: 0, to: t.count, by: max(1, t.count / 300)))
    var s: [Double] = []
    for a in 0..<idx.count { for b in (a + 1)..<idx.count where t[idx[b]] - t[idx[a]] > 30 { s.append((y[idx[b]] - y[idx[a]]) / (t[idx[b]] - t[idx[a]])) } }
    return median(s) * 60
}

func analyse() {
    guard let md = try? Data(contentsOf: runDir.appendingPathComponent("meta.json")), let meta = try? JSONDecoder().decode(Meta.self, from: md) else { say("no run data in \(runDir.path)"); exit(1) }
    let fs = meta.fs, micSR = meta.micSR, K = meta.names.count
    let outCB = (0..<K).map { loadBin("out\($0).bin", CB.self) }, micCB = loadBin("mic_cb.bin", MCB.self)
    let mic = loadBin("mic.i16", Int16.self).map { Float($0) / 32767 }
    let evs = (try? JSONDecoder().decode([Ev].self, from: Data(contentsOf: runDir.appendingPathComponent("events.json")))) ?? []
    let tStart = Double(micCB.first?.host ?? 0) * tick
    let C = SSCorrelator(log2n: 17)
    let codes = (0..<K).map { ultraCode(seed: UInt64(7001 + $0), fs: fs, peakDB: meta.codeDB) }, sw = sweep(fs: fs, peakDB: meta.sweepDB)

    // output sample position -> host seconds at which the HAL presents it (from that output's own timestamps)
    func outTime(_ k: Int, _ p: Int64) -> Double? {
        let c = outCB[k]; var lo = 0, hi = c.count - 1
        guard hi >= 0, c[0].pos <= p else { return nil }
        while lo < hi { let m = (lo + hi + 1) / 2; if c[m].pos <= p { lo = m } else { hi = m - 1 } }
        guard c[lo].outHost > 0 else { return nil }
        return Double(c[lo].outHost) * tick + Double(p - c[lo].pos) / fs
    }
    func nominalTime(_ k: Int, _ p: Int64) -> Double? { outCB[k].first.map { Double($0.outHost) * tick + Double(p - $0.pos) / fs } }
    func micIndex(_ t: Double) -> Double? {
        var lo = 0, hi = micCB.count - 1; guard hi >= 0 else { return nil }
        while lo < hi { let m = (lo + hi + 1) / 2; if Double(micCB[m].host) * tick <= t { lo = m } else { hi = m - 1 } }
        return Double(micCB[lo].pos) + (t - Double(micCB[lo].host) * tick) * micSR
    }
    /// Latency (s) of `sig` sent at host time te: search the mic 0–1.2 s later.
    func detect(_ te: Double, _ sig: [Float], _ band: (Double, Double)) -> (lat: Double, ratio: Float)? {
        let lo = -0.02, hi = 1.2
        guard let j0 = micIndex(te + lo), j0 >= 0 else { return nil }
        let count = Int((hi - lo) * fs) + sig.count
        guard Int(j0) + Int(Double(count) * micSR / fs) + 2 < mic.count else { return nil }
        let rec = mic.withUnsafeBufferPointer { SSDSP.resample($0, start: j0, from: micSR, to: fs, count: count) }
        let (lag, ratio) = SSCorrelator.peak(C.correlate(code: sig, recording: rec, sampleRate: fs, band: band, beta: 0, maxLag: count - sig.count))
        return (lo + Double(lag) / fs, ratio)
    }
    let good: Float = 10   // pure noise peaks reach ~7× the median

    // timestamp anomalies per output (layer-3 candidates)
    struct Anom { var t: Double; var kind: String; var ms: Double }
    var anoms = (0..<K).map { _ in [Anom]() }
    var ppm = [Double](repeating: .nan, count: K)
    for k in 0..<K {
        let c = outCB[k]; guard c.count > 10 else { continue }
        for i in 1..<c.count {
            let a = c[i - 1], b = c[i], t = Double(b.outHost) * tick - tStart, exp = Double(a.frames) / fs
            let gap = Double(b.now &- a.now) * tick
            if gap > max(2 * exp, 0.015) { anoms[k].append(Anom(t: t, kind: "callback gap", ms: gap * 1000)) }
            let dHost = (Double(b.outHost) - Double(a.outHost)) * tick - Double(b.pos - a.pos) / (fs * max(a.rate, 0.5))
            if abs(dHost) > 0.001 { anoms[k].append(Anom(t: t, kind: "host-time step", ms: dHost * 1000)) }
            let dS = b.sampleTime - a.sampleTime - Double(a.frames)
            if abs(dS) > 0.5 { anoms[k].append(Anom(t: t, kind: "sample-time step", ms: dS / fs * 1000)) }
        }
        // clock rate: sample time vs host time over the run (least squares on the second half, after start-up)
        let h = c[(c.count / 2)...]
        let xs = h.map { Double($0.outHost) * tick }, ys = h.map { $0.sampleTime }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0; for i in xs.indices { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx) }
        ppm[k] = (sxy / sxx / fs - 1) * 1e6
    }

    if meta.mode == "calibrate" {
        say("== A. Calibration repeatability (latency = mic arrival − the moment the Mac hands the sample to the output)")
        var lat = (0..<K).map { _ in [Double]() }
        for k in 0..<K {
            say("\n\(meta.names[k])")
            say("   rep  stream   sweep (audible)      code (inaudible)     sweep − code")
            var segs: [Int: [Double]] = [:], diffs: [Double] = []
            let ems = meta.emissions[k]
            for rep in 0..<8 {
                let pair = ems.filter { $0.rep == rep }
                guard let s = pair.first(where: { $0.kind == 0 }), let c = pair.first(where: { $0.kind == 1 }) else { continue }
                let ds = outTime(k, s.pos).flatMap { detect($0, sw, sweepBand) }, dc = outTime(k, c.pos).flatMap { detect($0, codes[k], ultraBand) }
                func cell(_ d: (lat: Double, ratio: Float)?) -> String { d.map { String(format: "%7.1f ms (%3.0f×)%@", $0.lat * 1000, $0.ratio, $0.ratio < good ? "?" : " ") } ?? "      –            " }
                var line = String(format: "   %d    %d        ", rep, s.seg) + cell(ds) + "   " + cell(dc)
                if let a = ds, let b = dc, a.ratio >= good, b.ratio >= good { line += String(format: "   %+.1f ms", (a.lat - b.lat) * 1000); diffs.append((a.lat - b.lat) * 1000) }
                say(line)
                if let a = ds, a.ratio >= good { segs[s.seg, default: []].append(a.lat * 1000); lat[k].append(a.lat * 1000) }
            }
            let within = segs.values.filter { $0.count > 1 }.map { ($0.max()! - $0.min()!) }
            let means = segs.keys.sorted().map { segs[$0]!.reduce(0, +) / Double(segs[$0]!.count) }
            say("   within one stream: spread ≤ \(within.max().map(f1) ?? "–") ms   (pass ≤ 2)")
            say("   stream starts: means " + means.map(f1).joined(separator: " / ") + " ms → change across restarts \(means.count > 1 ? f1(means.max()! - means.min()!) : "–") ms")
            if !diffs.isEmpty { say("   audible vs inaudible: mean \(f1(diffs.reduce(0, +) / Double(diffs.count))) ms, worst \(f1(diffs.map { abs($0) }.max()!)) ms   (pass ≤ 2)") }
        }
        if lat.allSatisfy({ !$0.isEmpty }) {
            say("\nOffsets vs \(meta.names[0]) (from the sweeps): " + (1..<K).map { "\(meta.names[$0]) \(String(format: "%+.1f", median(lat[$0]) - median(lat[0]))) ms" }.joined(separator: ", "))
        }
    } else {
        say("== B. Open loop, \(Int(meta.seconds / 60)) min, no corrections")
        // per output, per emission: arrival latency via timestamps (clock-compensated) and via nominal clock
        struct M { var t: Double; var ts: Double; var nom: Double }
        var series = (0..<K).map { _ in [M]() }
        for k in 0..<K {
            var miss = 0, ratios: [Float] = []
            for e in meta.emissions[k] {
                guard let te = outTime(k, e.pos), let tn = nominalTime(k, e.pos), let d = detect(te, codes[k], ultraBand) else { miss += 1; continue }
                ratios.append(d.ratio)
                if d.ratio < good { miss += 1; continue }
                let arrival = te + d.lat
                series[k].append(M(t: te - tStart, ts: d.lat * 1000, nom: (arrival - tn) * 1000))
            }
            say(String(format: "  %@: heard %d/%d codes (median %.0f× noise) · clock %+.1f ppm vs the Mac (timestamps)", meta.names[k], series[k].count, meta.emissions[k].count, Double(median(ratios.map { Double($0) })), ppm[k]))
        }
        // jumps in each output's own latency
        func jumps(_ s: [M]) -> [(t: Double, ms: Double)] {
            var out: [(t: Double, ms: Double)] = []; var i = 5
            while i + 5 <= s.count {
                let before = median(s[(i - 5)..<i].map { $0.ts }), after = median(s[i..<(i + 5)].map { $0.ts })
                if abs(after - before) >= 4 { out.append((s[i].t, after - before)); i += 5 } else { i += 1 }
            }
            return out
        }
        say("\n  Jumps (≥ 4 ms step in an output's own latency) and whether anything without the mic saw them (±2 s):")
        var caught = 0, total = 0
        for k in 0..<K {
            let js = jumps(series[k])
            let evK = evs.filter { $0.dev == meta.names[k] }
            say("  \(meta.names[k]): \(js.count) jumps · timestamp anomalies \(anoms[k].count) · device events \(evK.count)")
            for j in js.prefix(25) {
                let a = anoms[k].filter { abs($0.t - j.t) < 2 }, ev = evK.filter { abs($0.t - j.t) < 2 }
                total += 1; if !a.isEmpty || !ev.isEmpty { caught += 1 }
                say(String(format: "     %6.0f s  %+6.1f ms  → ", j.t, j.ms) + (a.isEmpty && ev.isEmpty ? "nothing" : (a.prefix(3).map { "\($0.kind) \(f1($0.ms)) ms" } + ev.prefix(2).map { "\($0.what)=\($0.value)" }).joined(separator: ", ")))
            }
            if js.count > 25 { say("     … \(js.count - 25) more") }
        }
        let anomTotal = anoms.reduce(0) { $0 + $1.count }
        say("  Layer 3 verdict: \(caught)/\(total) jumps had a non-mic signal (pass: most). Anomalies overall: \(anomTotal) (false alarms if far above the jump count).")

        // relative offsets vs the reference (what you'd hear) and simulated designs
        say("\n  Offset vs \(meta.names[0]) over time (what you'd hear), and how each design would have done (% of seconds within ±5 ms):")
        say("  output             drift(timestamps)  drift(no clock fix)   calib-once  +check 60 s  +check 10 s  +check 3 s")
        let ref = series[0]
        for k in 1..<K {
            var t: [Double] = [], r: [Double] = [], rn: [Double] = []
            for m in series[k] {
                var lo = 0, hi = ref.count - 1; guard hi >= 0 else { break }
                while lo < hi { let mid = (lo + hi) / 2; if ref[mid].t < m.t { lo = mid + 1 } else { hi = mid } }
                guard abs(ref[lo].t - m.t) < 1.1 else { continue }
                t.append(m.t); r.append(m.ts - ref[lo].ts); rn.append(m.nom - ref[lo].nom)
            }
            guard r.count > 20 else { say("  \(meta.names[k]): too few paired readings"); continue }
            func within(checkEvery S: Double) -> Double {
                var base = median(Array(r.prefix(5))), last = t[0], n = 0
                for i in r.indices { if S.isFinite, t[i] - last >= S { base = r[i]; last = t[i] }; if abs(r[i] - base) <= 5 { n += 1 } }
                return 100 * Double(n) / Double(r.count)
            }
            say(String(format: "  %-18@ %+7.2f ms/min      %+7.2f ms/min      %6.0f%%     %6.0f%%      %6.0f%%      %6.0f%%",
                       meta.names[k] as NSString, slopePerMin(t, r), slopePerMin(t, rn), within(checkEvery: .infinity), within(checkEvery: 60), within(checkEvery: 10), within(checkEvery: 3)))
            // save the series for plotting
            let csv = "t_s,offset_ms,offset_noclock_ms\n" + r.indices.map { String(format: "%.2f,%.2f,%.2f", t[$0], r[$0], rn[$0]) }.joined(separator: "\n")
            try? csv.write(to: runDir.appendingPathComponent("offset_\(k).csv"), atomically: true, encoding: .utf8)
        }
        say("  Layer 1 verdict: timestamp drift within ±2 ms over the run = clock layer works without the mic.")
        if !evs.isEmpty { say("\n  Device events: " + Dictionary(grouping: evs, by: { "\($0.dev) \($0.what)" }).map { "\($0.key) ×\($0.value.count)" }.sorted().joined(separator: ", ")) }
    }
    say("\ndone")
    exit(0)
}

// MARK: - start
if mode == "analyse" { analyse() }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
AVCaptureDevice.requestAccess(for: .audio) { ok in
    guard ok else { say("microphone permission denied"); exit(1) }
    DispatchQueue.global().async { record() }
}
app.run()
