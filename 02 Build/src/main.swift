// SpeakerSync v3 — keeps two or more audio outputs on this Mac in time, using a microphone.
// Model: see "01 Measurements & Findings/(C) Sync Model.md" in the Speaker Sync vault project.
import Foundation
import CoreAudio
import AppKit
import Accelerate
import AVFoundation
import Network

// MARK: - files and logging
let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/speakersync")
let logURL = dir.appendingPathComponent("log.txt"), statusURL = dir.appendingPathComponent("status.txt")
let relockURL = dir.appendingPathComponent("relock"), configURL = dir.appendingPathComponent("config.json")
let memDir = dir.appendingPathComponent("devices")
try? FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}
func writeStatus(_ s: String) { try? "\(Date())\n\(s)\n".write(to: statusURL, atomically: true, encoding: .utf8) }

// MARK: - Core Audio helpers
let sys = AudioObjectID(kAudioObjectSystemObject)
func A(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ el: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    .init(mSelector: s, mScope: sc, mElement: el) }
func ids(_ o: AudioObjectID, _ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var a = A(s, sc); var sz: UInt32 = 0; guard AudioObjectGetPropertyDataSize(o, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    var r = [AudioObjectID](repeating: 0, count: Int(sz) / 4); AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &r); return r }
func str(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = A(s); var v: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &v) == noErr else { return "" }; return (v?.takeRetainedValue() as String?) ?? "" }
func u32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
    var a = A(s, sc); var v: UInt32 = 0; var sz: UInt32 = 4; AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &v); return v }
func nominalRate(_ o: AudioObjectID) -> Double {
    var a = A(kAudioDevicePropertyNominalSampleRate); var v: Float64 = 0; var sz: UInt32 = 8
    AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &v); return v }
func setNominalRate(_ o: AudioObjectID, _ r: Double) { var a = A(kAudioDevicePropertyNominalSampleRate); var v = r; AudioObjectSetPropertyData(o, &a, 0, nil, 8, &v) }
func hasOutput(_ d: AudioObjectID) -> Bool { !ids(d, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).isEmpty }
func hasInput(_ d: AudioObjectID) -> Bool { !ids(d, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).isEmpty }
func setDefaultOutput(_ d: AudioObjectID) { var a = A(kAudioHardwarePropertyDefaultOutputDevice); var v = d; AudioObjectSetPropertyData(sys, &a, 0, nil, 4, &v) }
func defaultInput() -> AudioObjectID { var a = A(kAudioHardwarePropertyDefaultInputDevice); var v = AudioObjectID(0); var sz: UInt32 = 4; AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &v); return v }
/// A speaker's own hardware level (Bluetooth absolute volume), 0–1, averaged over its channels; 0 if muted.
/// Use the scalar: on these Bluetooth speakers the dB property is wrong (always reads ~0 dB, measured 2026-11-14).
func hwLevel(_ d: AudioObjectID) -> Float? {
    var m = A(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput); var mv: UInt32 = 0; var sz: UInt32 = 4
    if AudioObjectHasProperty(d, &m), AudioObjectGetPropertyData(d, &m, 0, nil, &sz, &mv) == noErr, mv != 0 { return 0 }
    var vals: [Float] = []
    for el in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
        var a = A(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, el); guard AudioObjectHasProperty(d, &a) else { continue }
        var v: Float32 = 0; sz = 4; if AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v) == noErr { vals.append(v) }
    }
    return vals.isEmpty ? nil : vals.reduce(0, +) / Float(vals.count)
}
func setHwLevel(_ d: AudioObjectID, _ v: Float) {
    for el in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
        var a = A(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, el); var w: DarwinBoolean = false
        guard AudioObjectHasProperty(d, &a), AudioObjectIsPropertySettable(d, &a, &w) == noErr, w.boolValue else { continue }
        var x = max(0, min(1, v)); AudioObjectSetPropertyData(d, &a, 0, nil, 4, &x)
    }
}
struct Dev { let id: AudioObjectID; let name: String; let uid: String }
func allDevices() -> [Dev] { ids(sys, kAudioHardwarePropertyDevices).map { Dev(id: $0, name: str($0, kAudioObjectPropertyName), uid: str($0, kAudioDevicePropertyDeviceUID)) } }
/// Real outputs a person would pick (no aggregates, multi-output devices or our own private devices).
func pickableOutputs() -> [Dev] {
    allDevices().filter { d in
        hasOutput(d.id) && !d.name.contains("SpeakerSync") &&
        u32(d.id, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeAggregate &&
        u32(d.id, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeVirtual
    }
}
func pickableInputs() -> [Dev] { allDevices().filter { hasInput($0.id) && u32($0.id, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeAggregate } }
func framesIn(_ l: UnsafeMutableAudioBufferListPointer) -> Int {
    guard let b = l.first, b.mNumberChannels > 0 else { return 0 }; return Int(b.mDataByteSize) / 4 / Int(b.mNumberChannels) }
func writeOut(_ l: UnsafeMutableAudioBufferListPointer, _ n: Int, _ f: (Int) -> (Float, Float)) {
    if l.count == 1, let d = l[0].mData?.assumingMemoryBound(to: Float.self) {
        let ch = Int(l[0].mNumberChannels)
        for i in 0..<n { let (L, R) = f(i); d[i * ch] = L; if ch > 1 { d[i * ch + 1] = R; if ch > 2 { for c in 2..<ch { d[i * ch + c] = 0 } } } }
    } else if l.count >= 2, let dl = l[0].mData?.assumingMemoryBound(to: Float.self), let dr = l[1].mData?.assumingMemoryBound(to: Float.self) {
        for i in 0..<n { let (L, R) = f(i); dl[i] = L; dr[i] = R }
    }
}
var tb = mach_timebase_info_data_t(); _ = mach_timebase_info(&tb)
let tts = Double(tb.numer) / Double(tb.denom) * 1e-9

// MARK: - GCC-PHAT
let fftLog2: vDSP_Length = 17, fftN = 1 << 17, half = (1 << 17) / 2
let fftSetup = vDSP_create_fftsetup(fftLog2, FFTRadix(kFFTRadix2))!
// Reused buffers: allocating ~2 MB of arrays every reading showed up in the profile.
var fIn = [Float](repeating: 0, count: fftN), fRe = [Float](repeating: 0, count: half), fIm = [Float](repeating: 0, count: half)
var fRe2 = [Float](repeating: 0, count: half), fIm2 = [Float](repeating: 0, count: half), fOut = [Float](repeating: 0, count: fftN)
func rfft(_ x: UnsafePointer<Float>, _ count: Int, _ re: inout [Float], _ im: inout [Float]) {
    let n = min(count, fftN)
    fIn.withUnsafeMutableBufferPointer { b in b.baseAddress!.update(from: x, count: n); if n < fftN { (b.baseAddress! + n).update(repeating: 0, count: fftN - n) } }
    re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
        var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        fIn.withUnsafeBytes { raw in vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &sc, 1, vDSP_Length(half)) }
        vDSP_fft_zrip(fftSetup, &sc, 1, fftLog2, FFTDirection(FFT_FORWARD))
    } }
}
/// GCC-PHAT. Writes |correlation| for lags lo...hi (samples the mic trails the sent audio) into cl; other entries untouched.
func gccPhat(_ m: UnsafePointer<Float>, _ mN: Int, _ sp: UnsafePointer<Float>, _ sN: Int, sr: Double, maxLag: Int, lo: Int, hi: Int, into cl: inout [Float]) {
    rfft(m, mN, &fRe, &fIm); rfft(sp, sN, &fRe2, &fIm2)
    let binHz = sr / Double(fftN), b0 = max(1, Int(150 / binHz)), b1 = min(half - 1, Int(7000 / binHz))
    fRe.withUnsafeMutableBufferPointer { mr in fIm.withUnsafeMutableBufferPointer { mi in fRe2.withUnsafeBufferPointer { sr2 in fIm2.withUnsafeBufferPointer { si in
        for k in 0..<half where k < b0 || k > b1 { mr[k] = 0; mi[k] = 0 }
        for k in b0...b1 {
            let a = mr[k], b = -mi[k], c = sr2[k], d = si[k]
            let x = a * c - b * d, y = a * d + b * c, mag = powf(x * x + y * y, 0.375) + 1e-20   // PHAT-beta 0.75
            mr[k] = x / mag; mi[k] = y / mag
        }
        var sc = DSPSplitComplex(realp: mr.baseAddress!, imagp: mi.baseAddress!)
        vDSP_fft_zrip(fftSetup, &sc, 1, fftLog2, FFTDirection(FFT_INVERSE))
        fOut.withUnsafeMutableBytes { raw in vDSP_ztoc(&sc, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half)) }
    } } } }
    for L in max(0, lo)...min(maxLag, hi) { cl[L] = abs(fOut[maxLag - L]) }
}
/// Noise floor: median of every 8th value in the window (same answer as a full sort, ~10x cheaper).
func noiseFloor(_ c: [Float], _ lo: Int, _ hi: Int) -> Float {
    var v = [Float](); v.reserveCapacity((hi - lo) / 8 + 1)
    var i = max(0, lo); while i <= min(c.count - 1, hi) { v.append(c[i]); i += 8 }
    guard !v.isEmpty else { return 1e-12 }
    v.sort(); return max(v[v.count / 2], 1e-12)
}
func argmax(_ c: [Float], _ lo: Int, _ hi: Int, excl: [ClosedRange<Int>] = []) -> (Int, Float) {
    var bi = -1; var bv: Float = -1; let a = max(0, lo), b = min(c.count - 1, hi); guard a <= b else { return (-1, -1) }
    for L in a...b { if excl.contains(where: { $0.contains(L) }) { continue }; if c[L] > bv { bv = c[L]; bi = L } }
    return (bi, bv)
}

// MARK: - configuration (config.json) and per-device memory
struct Config: Codable {
    var outputs: [String] = []          // device UIDs to keep in time
    var mic: String? = nil              // input UID; nil = built-in mic
    var reference: String? = nil        // reference output (clock + timing anchor)
    var referencePinned: Bool? = nil    // true = Vivaan chose it in the menu; otherwise the slowest output is used
    var standbyApps: [String] = ["rekordbox"]
    var paused: Bool = false
}
var config: Config = {
    if let d = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
    var c = Config()
    // first run of v3: carry over the Eris + Brane pair from v2
    for d in pickableOutputs() where (d.name.hasPrefix("Eris") && !d.name.contains("+")) || d.name.hasPrefix("Brane") { c.outputs.append(d.uid) }
    return c
}()
func saveConfig() { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(config).write(to: configURL) }
saveConfig()

// Self-tuning: each output scores its own sync results and learns which correction settings work for it (UCB bandit),
// learns its reading jitter to size the "leave it alone" band, and (in Engine.apply) learns its drift rate.
struct Arm: Codable { var window: Int; var gain: Double; var n = 0; var mean = 0.0 }
struct Round: Codable { var t: Double; var arm: Int; var reward: Double; var inSync: Double; var meanAbsMs: Double; var corrections: Int }
struct Learner: Codable {
    var arms: [Arm] = [3, 5, 7].flatMap { w in [0.4, 0.7].map { Arm(window: w, gain: $0) } }
    var current = 3                       // start at window 5, gain 0.7 (close to the hand-tuned v2 settings)
    var jitterMs = 3.0                    // learned reading-to-reading noise
    var rounds: [Round] = []
    var epN = 0, epIn = 0, epAbs = 0.0, epCorr = 0
    var arm: Arm { arms[current] }
    var deadbandMs: Double { min(10, max(4, 2.5 * jitterMs)) }
    mutating func observe(errMs: Double, prevMs: Double?, corrected: Bool) {
        epN += 1; epAbs += abs(errMs); if abs(errMs) <= 6 { epIn += 1 }
        if let p = prevMs, !corrected, abs(errMs - p) < 20 { let d2 = (errMs - p) * (errMs - p) / 2; jitterMs = (0.98 * jitterMs * jitterMs + 0.02 * d2).squareRoot() }
    }
    /// End a round after 100 clear readings: score it, update the arm, pick the next one. Returns a log line.
    /// `explore` false = this output isn't the one being tuned right now: it scores the round but stays on its best arm.
    /// With 3+ outputs only one output explores at a time, because a correction on one output moves spikes the others
    /// are read from, so simultaneous exploration blamed each output for the others' changes.
    mutating func maybeEndRound(explore: Bool = true) -> String? {
        guard epN >= 100 else { return nil }
        let inSync = Double(epIn) / Double(epN), meanAbs = epAbs / Double(epN)
        let reward = inSync - 0.02 * Double(epCorr) - 0.005 * meanAbs
        arms[current].n += 1; arms[current].mean += (reward - arms[current].mean) / Double(arms[current].n)
        rounds.append(Round(t: Date().timeIntervalSince1970, arm: current, reward: reward, inSync: inSync, meanAbsMs: meanAbs, corrections: epCorr))
        if rounds.count > 200 { rounds.removeFirst(rounds.count - 200) }
        let tried = arms[current]
        let total = Double(arms.reduce(0) { $0 + $1.n })
        if !explore { current = arms.indices.filter { arms[$0].n > 0 }.max { arms[$0].mean < arms[$1].mean }! }
        else if let untried = arms.indices.first(where: { arms[$0].n == 0 }) { current = untried }
        else { current = arms.indices.max { a, b in (arms[a].mean + 0.25 * (log(total) / Double(arms[a].n)).squareRoot()) < (arms[b].mean + 0.25 * (log(total) / Double(arms[b].n)).squareRoot()) }! }
        let best = arms.indices.filter { arms[$0].n > 0 }.max { arms[$0].mean < arms[$1].mean }!
        epN = 0; epIn = 0; epAbs = 0; epCorr = 0
        return (explore ? "" : "[holding best] ") + String(format: "round %d: wait %d / correct %.0f%% scored %.3f (%.0f%% in time, %.1f ms avg, %d corrections); best so far wait %d / %.0f%%; next wait %d / %.0f%%; noise band ±%.1f ms",
                      rounds.count, tried.window, tried.gain * 100, reward, inSync * 100, meanAbs, rounds.last!.corrections, arms[best].window, arms[best].gain * 100, arm.window, arm.gain * 100, deadbandMs)
    }
}
// Tuning is stored per setup (which outputs play together) and drift per reference clock: a 2-speaker profile
// and a 3-speaker profile are different problems and must not overwrite each other. `learner`/`rate` are the
// pre-iteration-9 single profile, kept only to migrate 2-output setups.
struct DevMemory: Codable {
    var rate: Double = 0; var lagMs: Double? = nil; var name: String = ""; var learner: Learner? = nil
    var profiles: [String: Learner]? = nil      // setup key -> tuning
    var rates: [String: Double]? = nil          // reference uid -> learned drift
    var amps: [String: Double]? = nil           // setup key -> loudness fingerprint learned from music
    var latencyMs: Double? = nil                // this output's own delay (incl. the mic path), from the last sweep or quiet re-lock
}
func memURL(_ uid: String) -> URL { memDir.appendingPathComponent(String(uid.map { $0.isLetter || $0.isNumber ? $0 : "_" }) + ".json") }
func loadMem(_ uid: String) -> DevMemory { (try? Data(contentsOf: memURL(uid))).flatMap { try? JSONDecoder().decode(DevMemory.self, from: $0) } ?? DevMemory() }
func saveMem(_ uid: String, _ m: DevMemory) { try? JSONEncoder().encode(m).write(to: memURL(uid)) }

struct Setup: Equatable { let outs: [AudioObjectID]; let uids: [String]; let names: [String]; let ref: Int; let mic: AudioObjectID }
func currentSetup() -> (Setup?, String) {
    if config.paused { return (nil, "paused") }
    let running = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName?.lowercased() }
    if let app = config.standbyApps.first(where: { a in running.contains(a.lowercased()) }) { return (nil, "\(app) is open, standing by") }
    let outs = pickableOutputs()
    let present = config.outputs.compactMap { u in outs.first { $0.uid == u } }
    guard present.count >= 2 else { return (nil, present.isEmpty ? "choose two or more outputs in the menu bar" : "only \(present.count) chosen output is connected") }
    let ins = pickableInputs()
    let mic = (config.mic.flatMap { u in ins.first { $0.uid == u } } ?? ins.first { $0.name.contains("MacBook") } ?? ins.first { $0.id == defaultInput() })?.id ?? 0
    guard mic != 0 else { return (nil, "no microphone found") }
    let ref = config.reference.flatMap { r in present.firstIndex { $0.uid == r } } ?? 0
    return (Setup(outs: present.map { $0.id }, uids: present.map { $0.uid }, names: present.map { $0.name }, ref: ref, mic: mic), "ok")
}

// MARK: - one output
final class Out {
    let id: AudioObjectID, uid: String, name: String
    var proc: AudioDeviceIOProcID?
    // audio-thread state (followers)
    var r: Int64 = 0, lagT: Int64 = 4096, resync = true, mute = false
    var meanLag = 4096.0, shiftReq: Int64 = 0, shiftDone: Int64 = 0, rateShift: Int64 = 0, rateAcc = 0.0, rate = 0.0
    var snaps = 0, slews = 0
    // main-thread tracking
    var hist: [Double] = [], lastCorrT: Date? = nil, lastErrMs = 0.0, relMs: Double? = nil, pred = 0.0, corrections = 0
    var soloP: Double? = nil, soloCand: Double? = nil, soloSNR = 0.0, amp = 1.0, ampLearned = false   // amp: this output's spike height ÷ the reference's
    var learn = Learner(), prevErrMs: Double? = nil
    var corrHist: [(t: Double, frames: Double)] = []   // recent drift slides, for the drift-rate estimate
    var lastCB: UInt64 = 0, gaps = 0, gapsSeen = 0       // audio-thread callback gaps = stream interruptions
    var level: Float = -1                                  // hardware level 0–1 (Bluetooth absolute volume)
    var trim: Float = 1, gainNow: Float = 1                // digital gain target (main thread) and ramped value (audio thread)
    init(_ id: AudioObjectID, _ uid: String, _ name: String) { self.id = id; self.uid = uid; self.name = name }
    var pendingFrames: Int64 { shiftReq + rateShift - shiftDone }
}

// MARK: - engine
final class Engine {
    let setup: Setup; var outs: [Out] = []; let ref: Int
    var sr = 44100.0, micSR = 48000.0
    let cap = 1 << 19, mask = (1 << 19) - 1, micCap = 1 << 21
    let ring = UnsafeMutablePointer<Float>.allocate(capacity: (1 << 19) * 2)
    let micBuf = UnsafeMutablePointer<Float>.allocate(capacity: 1 << 21)
    let aggAnch = UnsafeMutablePointer<(UInt64, Int64)>.allocate(capacity: 2)
    let micAnch = UnsafeMutablePointer<(UInt64, Int64)>.allocate(capacity: 2)
    var aggSeq = 0, micSeq = 0, w: Int64 = 0, micTotal: Int64 = 0
    var refHold: Int64 = 4096, followerGain: Float = 1
    var tap = AudioObjectID(0), agg = AudioObjectID(0), aggProc: AudioDeviceIOProcID?, micProc: AudioDeviceIOProcID?
    // tracking
    var phase = "solo", soloIdx = 0, phaseT = Date(), Pref = 0.0, clAvg: [Float] = []
    var echoes = 0, noisy = 0, lastState = "", unexplained: [Double] = [], probeQueue: [Int] = [], probeX = 0.0, probeIdx = -1
    var readings: [[String: Any]] = [], corrLog: [[String: Any]] = [], corrSnap: [Float] = [], corrBinMs = 1.0, lastSNR: Float = 0, lastSrcRms: Float = 0
    var spikesRel: [[String: Any]] = [], lastSummary = Date()
    // Mic window: 1.5 s to lock (needs the strongest peak), 0.75 s while tracking so a slip shows up twice as fast.
    var N = 65536
    let maxLag = 49152
    let startedAt = Date(); var tapStallLogged = false
    var mWin = [Float](repeating: 0, count: 65536), sWin = [Float](repeating: 0, count: 65536 + 49152), clRaw = [Float](repeating: 0, count: 49153)
    // Adaptive pace: measure every tick, then every 2nd (1.5 s) after 60 s in time, every 4th (3 s) after 5 min.
    // SyncLab showed a running Bluetooth stream holds its latency (JBL ±0.1 ms, Brane ±1.5 ms), so a settled
    // system needs only occasional checks; any out-of-band reading drops straight back to every tick.
    var paceDiv = 1, tickN = 0, stableSince: Date? = nil, readingsDone = 0
    var relaxed: Bool { paceDiv > 1 }
    func setPace(_ d: Int, _ why: String? = nil) {
        guard d != paceDiv else { return }
        prefVel *= Double(d) / Double(paceDiv); paceDiv = d
        if let w = why { log("pace: \(w), measuring every \(String(format: "%.2g", 0.75 * Double(d))) s") }
    }
    var deadSpikes: [(Double, Date)] = [], lastProbe = Date.distantPast, probes = 0, probeMisses = 0
    var prefVel = 0.0, lostRef = 0, lastGL: Int? = nil
    // Room reflections: a spike a nudge couldn't match is ignored for 60 s; after 2 misses at the same offset, for the session.
    var reflections: [Double] = [], reflectionMisses: [Double] = []
    func isReflection(_ r: Double) -> Bool { deadSpikes.contains { abs($0.0 - r) < 0.005 * sr } || reflections.contains { abs($0 - r) < 0.004 * sr } }
    func noteReflection(_ r: Double) {
        deadSpikes.append((r, Date()))
        if reflectionMisses.contains(where: { abs($0 - r) < 0.004 * sr }) { if !reflections.contains(where: { abs($0 - r) < 0.004 * sr }) { reflections.append(r); log(String(format: "learned a room reflection at %+.1f ms", ms(r))) } }
        reflectionMisses.append(r); if reflectionMisses.count > 20 { reflectionMisses.removeFirst() }
    }
    lazy var nudge: Int64 = Int64(0.010 * sr)   // 10 ms identification nudge (inaudible slide)
    var unknownReads = 0

    var followers: [Int] { outs.indices.filter { $0 != ref } }
    func ms(_ f: Double) -> Double { f / sr * 1000 }
    @inline(__always) func readFrame(_ p: Int64) -> (Float, Float) {
        if p < 0 || p >= w { return (0, 0) }; let i = Int(p) & mask; return (ring[i * 2], ring[i * 2 + 1]) }

    init?(_ s: Setup) {
        setup = s; ref = s.ref
        outs = s.outs.indices.map { Out(s.outs[$0], s.uids[$0], s.names[$0]) }
        ring.initialize(repeating: 0, count: cap * 2); micBuf.initialize(repeating: 0, count: micCap)
        aggAnch[0] = (0, 0); aggAnch[1] = (0, 0); micAnch[0] = (0, 0); micAnch[1] = (0, 0)
        let refDev = s.outs[ref]
        for o in outs where nominalRate(o.id) != nominalRate(refDev) { setNominalRate(o.id, nominalRate(refDev)) }
        if let bad = outs.first(where: { nominalRate($0.id) != nominalRate(refDev) }) { log("can't match sample rates: \(bad.name) \(nominalRate(bad.id)) vs \(nominalRate(refDev))"); return nil }
        sr = nominalRate(refDev); micSR = nominalRate(s.mic)
        sweepSig = Engine.makeSweep(sr: sr); calPeriod = Int64(1.5 * sr)
        setDefaultOutput(refDev)
        // warm start from each device's memory: tuning for this exact set of outputs, drift vs this reference
        for o in outs {
            let m = loadMem(o.uid)
            o.rate = m.rates?[s.uids[ref]] ?? 0      // old single rates were pinned at the cap (runaway): not migrated
            if let l = m.profiles?[setupKey] { o.learn = l } else if outs.count == 2, let l = m.learner { o.learn = l; o.learn.jitterMs = 3 }
            if let l = m.lagMs { if o === outs[ref] { refHold = min(maxRefHold, max(2048, Int64(l * sr / 1000))) } else { o.lagT = clampLag(Int64(l * sr / 1000)) } }
            o.meanLag = Double(o.lagT)
        }
        log("engine start: \(outs.map { $0.name }.joined(separator: " + ")) · reference \(outs[ref].name) · mic \(str(s.mic, kAudioObjectPropertyName)) · \(sr) Hz")

        for i in followers {
            let o = outs[i]
            guard AudioDeviceCreateIOProcIDWithBlock(&o.proc, o.id, nil, { [unowned self, unowned o] now, _, _, out, _ in
                // free-running: Bluetooth pulls in bursts, so only mic-measured shifts move this output
                let ol = UnsafeMutableAudioBufferListPointer(out); let n = framesIn(ol); guard n > 0 else { return }
                let h = now.pointee.mHostTime; if o.lastCB > 0, Double(h &- o.lastCB) * tts > 0.25 { o.gaps += 1 }; o.lastCB = h
                if self.w == 0 { writeOut(ol, n) { _ in (0, 0) }; o.resync = true; return }
                if o.resync { o.r = self.w - o.lagT; o.meanLag = Double(o.lagT); o.resync = false }
                let lag = self.w - o.r
                o.meanLag = o.meanLag * 0.999 + Double(lag) * 0.001
                if lag < 256 { o.r = self.w - 2048; o.snaps += 1 } else if lag > 60000 { o.r = self.w - o.lagT; o.snaps += 1 }
                o.rateAcc += o.rate * Double(n); let ex = Int64(o.rateAcc); o.rateAcc -= Double(ex); o.rateShift += ex
                let rem = o.pendingFrames, k = Int(min(4, abs(rem))), dirn: Int64 = rem > 0 ? 1 : -1
                if k > 0 { o.shiftDone += dirn * Int64(k); o.slews += k }
                let step = k > 0 ? max(1, n / (k + 1)) : Int.max
                let tgt: Float = o.mute ? 0 : self.followerGain * o.trim; var g = o.gainNow
                writeOut(ol, n) { i in
                    if k > 0 && i > 0 && i % step == 0 && i / step <= k { o.r += dirn }
                    g += (tgt - g) * 0.0002   // ~0.1 s ramp: mutes and level spotlights never click
                    let s = self.readFrame(o.r); o.r += 1; return (s.0 * g, s.1 * g) }
                o.gainNow = g
            }) == noErr, AudioDeviceStart(o.id, o.proc) == noErr else { log("couldn't start \(o.name)"); teardown(); return nil }
        }

        guard AudioDeviceCreateIOProcIDWithBlock(&micProc, s.mic, nil, { [unowned self] _, inp, inTime, _, _ in
            let il = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inp))
            guard let b = il.first, b.mNumberChannels > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = Int(b.mNumberChannels), n = Int(b.mDataByteSize) / 4 / ch
            if inTime.pointee.mFlags.contains(.hostTimeValid) { let q = self.micSeq + 1; self.micAnch[q & 1] = (inTime.pointee.mHostTime, self.micTotal); self.micSeq = q }
            for i in 0..<n { self.micBuf[Int(self.micTotal + Int64(i)) & (self.micCap - 1)] = d[i * ch] }
            self.micTotal += Int64(n)
        }) == noErr, AudioDeviceStart(s.mic, micProc) == noErr else { log("mic start failed"); teardown(); return nil }
        Thread.sleep(forTimeInterval: 0.3)

        var pid = getpid(), me = AudioObjectID(0), psz: UInt32 = 4
        var pa = A(kAudioHardwarePropertyTranslatePIDToProcessObject)
        AudioObjectGetPropertyData(sys, &pa, 4, &pid, &psz, &me)
        let td = CATapDescription(stereoGlobalTapButExcludeProcesses: me != 0 ? [me] : [])
        td.name = "SpeakerSync"; td.isPrivate = true; td.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(td, &tap) == noErr else { log("tap failed"); teardown(); return nil }
        let refUID = s.uids[ref]
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpeakerSync Tap", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceMainSubDeviceKey: refUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: refUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: td.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg) == noErr else { log("aggregate failed"); teardown(); return nil }
        let refOut = outs[ref]
        guard AudioDeviceCreateIOProcIDWithBlock(&aggProc, agg, nil, { [unowned self, unowned refOut] _, inp, inTime, out, _ in
            let il = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inp)), ol = UnsafeMutableAudioBufferListPointer(out)
            let n = framesIn(il)
            if inTime.pointee.mFlags.contains(.hostTimeValid) { let q = self.aggSeq + 1; self.aggAnch[q & 1] = (inTime.pointee.mHostTime, self.w); self.aggSeq = q
                let h = inTime.pointee.mHostTime; if refOut.lastCB > 0, Double(h &- refOut.lastCB) * tts > 0.25 { refOut.gaps += 1 }; refOut.lastCB = h }
            if n > 0 {
                if self.calibrating {
                    let sw = self.sweepSig, P = self.calPeriod
                    for i in 0..<n { let p = self.w + Int64(i), j = Int(p) & self.mask, m = Int(p % P); let v: Float = m < sw.count ? sw[m] : 0; self.ring[j * 2] = v; self.ring[j * 2 + 1] = v }
                } else if il.count == 1, let d = il[0].mData?.assumingMemoryBound(to: Float.self) {
                    let ch = Int(il[0].mNumberChannels)
                    for i in 0..<n { let j = (Int(self.w) + i) & self.mask; let L = d[i * ch]; self.ring[j * 2] = L; self.ring[j * 2 + 1] = ch > 1 ? d[i * ch + 1] : L }
                } else if il.count >= 2, let dl = il[0].mData?.assumingMemoryBound(to: Float.self), let dr = il[1].mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<n { let j = (Int(self.w) + i) & self.mask; self.ring[j * 2] = dl[i]; self.ring[j * 2 + 1] = dr[i] }
                }
                self.w += Int64(n)
            }
            let rem = self.refNudgeReq - self.refNudgeDone; if rem != 0 { self.refNudgeDone += rem > 0 ? min(4, rem) : max(-4, rem) }   // slewed like followers: inaudible
            let on = framesIn(ol), start = self.w - Int64(on) - self.refHold - self.refNudgeDone, muted = refOut.mute
            let tgt: Float = muted ? 0 : refOut.trim; var g = refOut.gainNow
            writeOut(ol, on) { i in g += (tgt - g) * 0.0002; let s = self.readFrame(start + Int64(i)); return (s.0 * g, s.1 * g) }
            refOut.gainNow = g
        }) == noErr, AudioDeviceStart(agg, aggProc) == noErr else { log("aggregate start failed"); teardown(); return nil }
        // Layer 3 (events): macOS's latency figure is wrong as a number, but it changes exactly when a Bluetooth
        // speaker renegotiates its buffer (seen on the Brane in SyncLab), which is when a calibration goes stale.
        for (i, o) in outs.enumerated() {
            var a = A(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
            guard AudioObjectHasProperty(o.id, &a) else { continue }
            let blk: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.requestRecal(i, "macOS reports \(o.name)'s delay changed") }
            if AudioObjectAddPropertyListenerBlock(o.id, &a, DispatchQueue.main, blk) == noErr { listeners.append((o.id, a, blk)) }
        }
        // Launch = sweep (Vivaan, 2026-11-15). A launch restarts every Bluetooth stream, which is exactly what moves each
        // speaker's delay (up to 230 ms), and the quiet re-lock found everyone at launch only 1 time in 3 (the Eris is hard to
        // pick out in music; the Brane's delay is still settling). During listening, every event uses the quiet re-lock.
        // quietStart() stays for a later attempt at a sweep-free launch.
        startLock()
    }

    func teardown() {
        for (id, addr, blk) in listeners { var a = addr; AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, blk) }; listeners = []
        if let p = aggProc { AudioDeviceStop(agg, p); AudioDeviceDestroyIOProcID(agg, p); aggProc = nil }
        for o in outs { if let p = o.proc { AudioDeviceStop(o.id, p); AudioDeviceDestroyIOProcID(o.id, p); o.proc = nil } }
        if let p = micProc { AudioDeviceStop(setup.mic, p); AudioDeviceDestroyIOProcID(setup.mic, p); micProc = nil }
        if agg != 0 { AudioHardwareDestroyAggregateDevice(agg); agg = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        log("engine stopped")
    }

    func lagMs(_ i: Int) -> Double { i == ref ? ms(Double(refHold)) : ms(outs[i].meanLag) }
    var setupKey: String { setup.uids.sorted().joined(separator: "+") }
    func saveMemories() {
        for (i, o) in outs.enumerated() {
            var m = loadMem(o.uid); m.lagMs = lagMs(i); m.name = o.name
            var p = m.profiles ?? [:]; p[setupKey] = o.learn; m.profiles = p
            var r = m.rates ?? [:]; r[setup.uids[ref]] = o.rate; m.rates = r
            if i != ref, o.ampLearned { var a = m.amps ?? [:]; a[setupKey] = o.amp; m.amps = a }
            if lastPhys.count == outs.count { m.latencyMs = ms(lastPhys[i]) }
            saveMem(o.uid, m)
        }
    }
    // Only one follower explores tuning settings at a time (3+ outputs); the rest hold their best.
    var tuner = 0
    var tunerIdx: Int { followers[tuner % followers.count] }

    /// Drift rate from the net of recent drift slides. Clock drift pushes the same way every time; noise and
    /// identity mix-ups (common with 3+ outputs) push both ways. Learning per correction ran away to the ±0.6 ms/s
    /// cap with both followers; real Bluetooth clocks differ by well under 0.15 ms/s (150 ppm).
    func learnRate(_ o: Out) {
        let now = Date().timeIntervalSince1970
        o.corrHist.removeAll { now - $0.t > 240 }
        guard o.corrHist.count >= 3, let first = o.corrHist.first, now - first.t >= 20 else { return }   // 60 s was too slow to help a creeping speaker
        let net = o.corrHist.reduce(0) { $0 + $1.frames }, total = o.corrHist.reduce(0) { $0 + abs($1.frames) }
        guard abs(net) >= 0.75 * total else { return }
        let est = net / ((now - first.t) * sr), old = o.rate
        o.rate = max(-0.00015, min(0.00015, o.rate + 0.5 * est))
        o.corrHist.removeAll()
        log(String(format: "learned drift for %@: %+.3f -> %+.3f ms/s (net %+.1f ms over %.0f s)", o.name, old * 1000, o.rate * 1000, ms(net), now - first.t))
    }

    // MARK: lock: each output plays alone once so its spike can be named
    // Buffer limits. A follower buffer past ~1.36 s makes the IOProc re-snap on every callback; earlier versions only
    // ever grew buffers (bad lock readings and hold-backs were added and saved), reaching a 0.32 s reference hold and
    // 2–4 s follower buffers. Every lock now rebuilds buffers from the measured latencies instead.
    // up to 1 s: a pinned reference faster than the slowest output must wait for it (e.g. the Eris holding back ~150–300 ms for the Brane)
    var maxRefHold: Int64 { Int64(1.0 * sr) }
    func clampLag(_ l: Int64) -> Int64 { max(3072, min(Int64(1.1 * sr), l)) }
    // ~200 ms of headroom so a follower can be moved ~130 ms earlier without touching the reference. At 93 ms a Brane jump of
    // 109 ms forced the Eris (reference) to jump 138 ms instead, an audible lurch (2026-11-15). Costs ~100 ms more total delay.
    var minFollowerLag: Double { 0.2 * sr }
    var lockRetries = 0
    var refHeard = true
    /// Levels: read each speaker's hardware level every tick. Identity with 3+ outputs rests on the loudness fingerprint
    /// (spike height ÷ the reference's), so a level change, from the menu or the speaker's own buttons, would make it
    /// stale and swap identities. Rescale it at once instead: amplitude ≈ level² (audio-taper approximation; the
    /// running refinement corrects the rest). A reference change rescales everyone, since fingerprints are relative to it.
    func updateLevels() {
        var ratio = [Double](repeating: 1, count: outs.count), changed: [String] = []
        for (i, o) in outs.enumerated() {
            guard let v = hwLevel(o.id) else { continue }
            if o.level >= 0, abs(v - o.level) > 0.01 {
                let r = Double(max(v, 0.02) / max(o.level, 0.02)); ratio[i] = r * r
                changed.append(String(format: "%@ %.0f%% → %.0f%%", o.name, o.level * 100, v * 100))
            }
            o.level = v
        }
        guard !changed.isEmpty else { return }
        for i in followers { outs[i].amp = max(0.1, min(3, outs[i].amp * ratio[i] / ratio[ref])) }
        log("levels: " + changed.joined(separator: ", ") + " · fingerprints now " + followers.map { String(format: "%@ %.2f", outs[$0].name, outs[$0].amp) }.joined(separator: ", "))
        saveMemories()
    }
    var loudIdx = 0, loudStart = Date(), loudSNR: [Double] = []
    var lastPhys: [Double] = [], suspectSpike: Double? = nil   // to check whether a far-spike re-calibration found a real jump
    // Level spotlight (Vivaan's idea, 2026-11-14): to find who owns a stray spike, turn every other output down 3 dB for
    // one reading, one candidate at a time. The owner's spike stands out ~41% more against the rest; for anyone else it
    // stays put or shrinks. Unlike the 10 ms timing nudge, this also works for the reference, which nudges can't move.
    let spotGain: Float = 0.708   // −3 dB, ramped over ~0.1 s
    let useSpotlight = false
    let settle = 6   // readings (~1.5 s at 0.25 s) a small error must hold on one side before it's corrected
    var spotX = 0.0, spotStep = 0, spotBase = 0.0, spotRel: [Double] = [], spotStart = Date(), lastSpot = Date.distantPast, spots = 0
    func spotRatio(_ cl: [Float]) -> Double? {
        let r = Int(0.003 * sr), x = Int(Pref + spotX)
        let (_, vx) = argmax(cl, x - r, x + r), (_, vm) = argmax(cl, Int(Pref) - r, Int(Pref) + r)
        return vm > 0 && vx > 0 ? Double(vx / vm) : nil
    }
    func startSpot(_ x: Double) {
        spotX = x; spotStep = 0; spotRel = []; spotBase = 0; spotStart = Date(); lastSpot = Date(); spots += 1
        for o in outs { o.trim = 1 }
        phase = "spot"; phaseT = Date(); status("checking which speaker is off (subtle level check)")
    }
    /// Test: shift one output by `msv` without telling the tracker, as a Bluetooth buffer jump would (positive = later).
    func injectSlip(_ i: Int, _ msv: Double) {
        guard outs.indices.contains(i) else { return }
        let f = Int64(msv * sr / 1000)
        if i == ref { refHold += f } else { let o = outs[i]; o.lagT = clampLag(Int64(o.meanLag) - o.pendingFrames + f); o.shiftReq = o.shiftDone; o.rateShift = 0; o.resync = true }
        log(String(format: "test: injected a %+.0f ms slip on %@", msv, outs[i].name))
    }
    // MARK: quiet re-lock (no sweep)
    // SyncLab: a speaker's delay holds while its stream runs and moves (up to 230 ms) when a stream starts, so a sweep is
    // only needed to meet a speaker. After that, start from each speaker's saved delay and find where it really is in the
    // music: slide one speaker 10 ms (slowly, inaudible) and see which spike moves. The reference is slid too, so every
    // speaker is located with no sweep, no muting and no level dips. Then rebuild the buffers from what was found.
    var refNudgeReq: Int64 = 0, refNudgeDone: Int64 = 0
    var scanIdx = 0, scanSub = 0, scanBefore: [Float] = [], scanLag: [Double] = [], scanPhys: [Double?] = [], quietFails = 0
    var seen: [[Double]] = [], quietPass = 0   // sightings of each output's own delay across the passes of one quiet re-lock
    func nudgeOut(_ k: Int, _ f: Int64) { if k == ref { refNudgeReq += f } else { outs[k].shiftReq -= f } }   // + = later, − = earlier
    func quietStart() -> Bool {
        let lat = outs.map { loadMem($0.uid).latencyMs }
        guard lat.allSatisfy({ $0 != nil }) else { return false }
        rebuildBuffers(lat.map { $0! * sr / 1000 })
        for i in followers { if let a = loadMem(outs[i].uid).amps?[setupKey] { outs[i].amp = a; outs[i].ampLearned = true } }
        log("quiet start: using each speaker's saved delay (" + outs.indices.map { String(format: "%@ %.0f ms", outs[$0].name, lat[$0]!) }.joined(separator: ", ") + ")")
        startQuiet("checking the saved delays")
        return true
    }
    func rebuildBuffers(_ phys: [Double]) {
        let T = max(phys[ref] + 2048, followers.map { phys[$0] + minFollowerLag }.max() ?? 0)
        refHold = min(maxRefHold, Int64(T - phys[ref])); Pref = phys[ref] + Double(refHold); prefVel = 0; lostRef = 0
        for i in followers { let o = outs[i]; o.lagT = clampLag(Int64(T - phys[i])); o.shiftReq = o.shiftDone; o.rateShift = 0; o.resync = true; o.hist.removeAll(); o.pred = 0 }
        lastPhys = phys
    }
    func startQuiet(_ why: String, fresh: Bool = true) {
        if fresh { seen = Array(repeating: [], count: outs.count); quietPass = 0 }
        quietPass += 1
        log(fresh ? "quiet re-lock: \(why); finding each speaker with inaudible 10 ms slides (no sweep)" : "quiet re-lock: pass \(quietPass): \(why)")
        for o in outs { o.trim = 1; o.hist.removeAll() }; unmuteAll(); calibrating = false
        scanIdx = 0; scanSub = 0; scanLag = []; scanPhys = Array(repeating: nil, count: outs.count)
        lockStartedAt = Date(); paceDiv = 1; stableSince = nil
        phase = "scan"; phaseT = Date(); status("re-locking quietly")
    }
    func scanStep(_ cl: [Float], noise: Float, lo: Int, hi: Int) {
        if scanSub == 0 { scanBefore = cl; scanLag = outs.indices.map { Double(lagFrames($0)) }; nudgeOut(scanIdx, -nudge); scanSub = 1; phaseT = Date(); return }
        // which spike moved 10 ms earlier? (a spike shared with others stays and a new one appears 10 ms before it). Sliding
        // earlier, not later: the room's reflections sit 10–30 ms after each spike (learned at +10, +15, +21 ms on 2026-11-15)
        // and hid a 10 ms-later copy; nothing arrives before the direct sound, so that side is clean.
        let n = Int(nudge), r = Int(0.0015 * sr), (_, amax) = argmax(cl, lo, hi)
        var best: (score: Float, at: Int)? = nil, excl: [ClosedRange<Int>] = []
        for _ in 0..<6 {
            let (p, v) = argmax(scanBefore, lo + n, hi, excl: excl); guard p >= 0, v > 5 * noise else { break }
            excl.append((p - Int(0.002 * sr))...(p + Int(0.002 * sr)))
            let (_, b0) = argmax(scanBefore, p - n - r, p - n + r), (_, a1) = argmax(cl, p - n - r, p - n + r)
            guard a1 >= 0.25 * amax, a1 > 5 * noise, a1 > 1.5 * b0 else { continue }
            if best == nil || a1 - b0 > best!.score { best = (a1 - b0, p) }
        }
        nudgeOut(scanIdx, nudge)   // slide it back
        let o = outs[scanIdx]
        if let b = best, (Double(b.at) - scanLag[scanIdx]) > 0.02 * sr, (Double(b.at) - scanLag[scanIdx]) < 0.9 * sr { scanPhys[scanIdx] = Double(b.at) - scanLag[scanIdx]; seen[scanIdx].append(scanPhys[scanIdx]!); log(String(format: "quiet re-lock: %@ is at %+.1f ms (own delay %.0f ms)", o.name, ms(Double(b.at) - Pref), ms(scanPhys[scanIdx]!))) }
        else { log("quiet re-lock: couldn't pick out \(o.name) this pass") }
        scanSub = 0; scanIdx += 1; phaseT = Date()
        if scanIdx < outs.count { return }
        finishQuiet()
    }
    /// Combine sightings from up to four passes (one pass misses a speaker ~40% of the time). A shift every speaker shares is
    /// the measuring frame (the mic-to-capture timing changes on every launch: everyone read ~+100 ms on 2026-11-15) and only
    /// re-anchors the tracker, inaudibly. Only movement relative to the reference changes buffers, and a relative move over
    /// 20 ms must be seen twice within 3 ms first (music repeats, so a far speaker can match the wrong beat).
    func finishQuiet() {
        phase = "track"; phaseT = Date(); unexplained = []; clAvg = []
        func pick(_ i: Int) -> Double? {
            let v = seen[i].sorted(); guard !v.isEmpty else { return nil }
            var best = (Double.infinity, v[v.count / 2])
            for k in 1..<max(1, v.count) where v.count > 1 { let d = v[k] - v[k - 1]; if d < best.0 { best = (d, (v[k] + v[k - 1]) / 2) } }
            return v.count == 1 || best.0 < 0.003 * sr ? (v.count == 1 ? v[0] : best.1) : v[v.count / 2]
        }
        let have = lastPhys.count == outs.count
        var phys: [Double] = [], need: [String] = []
        for i in outs.indices { if let p = pick(i) { phys.append(p) } else { phys.append(.nan); need.append(outs[i].name) } }
        if need.isEmpty, have {
            for i in followers {
                let rel = ms((phys[i] - phys[ref]) - (lastPhys[i] - lastPhys[ref]))
                let v = seen[i].sorted(), twice = v.count >= 2 && zip(v, v.dropFirst()).contains { $1 - $0 < 0.003 * sr }
                if abs(rel) > 20 && !twice { need.append("\(outs[i].name) (moved \(Int(rel)) ms, confirming)") }
            }
        }
        if need.isEmpty {
            quietFails = 0
            let relMax = have ? (followers.map { abs(ms((phys[$0] - phys[ref]) - (lastPhys[$0] - lastPhys[ref]))) }.max() ?? 0) : .infinity
            if relMax < 3 {
                Pref = phys[ref] + Double(refHold); prefVel = 0; lastPhys = phys; saveMemories()
                log(String(format: "quiet re-lock: everyone in time with each other (max %.1f ms); re-anchored only, nothing moved", relMax)); return
            }
            rebuildBuffers(phys); saveMemories()
            log(String(format: "quiet re-lock: corrected (largest move %.0f ms) with no sweep; total delay from the Mac ≈ %.0f ms", relMax, ms(phys[ref] + Double(refHold))))
            return
        }
        if quietPass < 4 { startQuiet("still need " + need.joined(separator: ", "), fresh: false); return }
        log("quiet re-lock: after 4 passes still missing " + need.joined(separator: ", ") + ", so falling back to a sweep calibration"); startLock()
    }
    func setSpotlight(_ k: Int) { for (i, o) in outs.enumerated() { o.trim = i == k ? 1 : spotGain }; phaseT = Date() }
    func finishSpot() {
        for o in outs { o.trim = 1 }
        phase = "track"; phaseT = Date(); unexplained = []
        let ratios = spotRel.map { spotBase > 0 ? $0 / spotBase : 0 }
        let order = ratios.indices.sorted { ratios[$0] > ratios[$1] }
        guard let b = order.first, ratios[b] >= 1.2, order.count < 2 || ratios[b] - ratios[order[1]] >= 0.15 else {
            log(String(format: "level check: no speaker owns the %+.1f ms spike (rises: %@), treating it as a reflection", ms(spotX), ratios.map { String(format: "%.2f", $0) }.joined(separator: "/")))
            noteReflection(spotX); return
        }
        let o = outs[b]
        log(String(format: "level check: the %+.1f ms spike is %@ (it stood out %.0f%% more when the others were 3 dB down; others %@)", ms(spotX), o.name, (ratios[b] - 1) * 100, order.dropFirst().map { String(format: "%.2f", ratios[$0]) }.joined(separator: "/")))
        if b == ref {
            // the tracker had latched onto the followers; the reference is really at Pref + spotX. Re-anchor, move the others to it.
            log(String(format: "re-locking: %@ (reference) moved %+.1f ms; moving the others to match", o.name, ms(spotX)))
            Pref += spotX; prefVel = 0; lostRef = 0
            let x = spotX; for j in followers { outs[j].hist.removeAll(); apply(j, -x, gain: 1, drift: false); if phase != "track" { return } }
        } else {
            log(String(format: "re-locking: %@ %+.1f ms", o.name, ms(spotX)))
            apply(b, spotX, gain: 1, drift: false)
        }
    }
    // Re-calibration on stream events. SyncLab measured that every stream start moves a Bluetooth speaker's delay
    // (up to 230 ms on the Brane) while a running stream holds it, so calibrate at each start, not continuously.
    var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var recalReq: String? = nil, lockStartedAt = Date.distantPast
    func requestRecal(_ i: Int, _ why: String) {
        if phase == "solo" {
            if i == soloIdx { outs[i].soloCand = nil; phaseT = Date(); return }   // measuring it right now: just re-confirm
            if outs[i].soloP == nil { return }                                    // not measured yet: nothing stale
        }
        if recalReq == nil { recalReq = why }
    }
    // Sweep calibration (from SyncLab, 2026-11-14): during a lock the ring carries a known 0.4 s log sweep every 1.5 s
    // instead of the music, and only the output being measured is unmuted. A sweep gives one sharp, unambiguous
    // correlation peak; locking on music gave false peaks (beats repeat), e.g. "Eris −726 ms". It also locks with
    // the music paused. The 1.5 s period is longer than the 1.11 s search range, so neighbouring sweeps can't alias.
    var calibrating = false, sweepSig: [Float] = [], calPeriod: Int64 = 66150
    static func makeSweep(sr: Double) -> [Float] {
        let T = 0.4, n = Int(T * sr), f0 = 200.0, f1 = 12000.0, k = log(f1 / f0), fade = 0.005 * sr
        return (0..<n).map { i in
            let e = min(1, Double(min(i, n - 1 - i)) / fade), env = 0.5 - 0.5 * cos(Double.pi * e)
            return Float(0.1 * env * sin(2 * Double.pi * f0 * T / k * (exp(Double(i) / sr / T * k) - 1)))   // −20 dBFS peak
        }
    }

    func startLock() {
        paceDiv = 1; stableSince = nil; prefVel = 0; lostRef = 0; lockRetries = 0
        // start from minimal buffers so every output's spike lands inside the 0–1.1 s search window
        refHold = 2048
        for i in followers { let o = outs[i]; o.lagT = 3072; o.shiftReq = o.shiftDone; o.rateShift = 0; o.resync = true }
        calibrating = true; lockStartedAt = Date(); recalReq = nil; loudSNR = []; quietFails = 0; refNudgeReq = refNudgeDone
        for o in outs { o.trim = 1 }
        log("calibrating: a short sweep from each output in turn (music muted for a few seconds)")
        for o in outs { o.hist.removeAll(); o.soloP = nil; o.soloCand = nil; o.lastCorrT = nil; o.corrHist.removeAll(); o.prevErrMs = nil }
        clAvg = []; unexplained = []; probeQueue = []; probeIdx = -1
        phase = "solo"; soloIdx = 0; setSolo(0)
    }
    func setSolo(_ k: Int) { for (i, o) in outs.enumerated() { o.mute = (i != k) }; phaseT = Date() }
    func unmuteAll() { for o in outs { o.mute = false } }

    /// Mic window mapped onto ring positions, plus the matching sent audio.
    func grab() -> Float? {
        let (aHu, aPi) = aggAnch[aggSeq & 1], (mHu, mIi) = micAnch[micSeq & 1]
        guard aHu > 0, mHu > 0 else { return nil }
        let aP = Double(aPi), mI = Double(mIi), off = (Double(aHu) - Double(mHu)) * tts, mT = micTotal, W = w
        func micIdx(_ p: Double) -> Double { mI + ((p - aP) / sr + off) * micSR }
        let pEnd = aP + ((Double(mT - 512) - mI) / micSR - off) * sr
        let p0 = Int64(min(pEnd, Double(W))) - Int64(N)
        guard p0 - Int64(maxLag) > W - Int64(cap) + 4096, micIdx(Double(p0)) > Double(mT - Int64(micCap) + 64) else { return nil }
        for n in 0..<N {
            let x = micIdx(Double(p0 + Int64(n))), fl = floor(x), i = Int64(fl), f = Float(x - fl)
            let a = micBuf[Int(i & Int64(micCap - 1))], b = micBuf[Int((i + 1) & Int64(micCap - 1))]; mWin[n] = a + (b - a) * f
        }
        var e: Float = 0
        for j in 0..<(N + maxLag) { let q = Int(p0 - Int64(maxLag) + Int64(j)) & mask; let v = 0.5 * (ring[q * 2] + ring[q * 2 + 1]); sWin[j] = v; if j >= maxLag { e += v * v } }
        return (e / Float(N)).squareRoot()
    }

    func status(_ s: String) {
        lastState = s
        var lines = ["outputs: \(outs.count) · reference \(outs[ref].name)", "state: \(s)"]
        for (i, o) in outs.enumerated() {
            if i == ref { lines.append("  \(o.name): reference, hold-back \(Int(lagMs(i))) ms, level \(Int(o.level * 100))%") }
            else { lines.append("  \(o.name): \(o.relMs.map { String(format: "%+.1f ms", $0) } ?? "–") vs reference · drift \(String(format: "%+.2f", o.rate * 1000)) ms/s · \(o.corrections) corrections")
                   lines.append(String(format: "      learning: wait %d, correct %.0f%%, band ±%.1f ms, round %d/100, %d rounds done", o.learn.arm.window, o.learn.arm.gain * 100, o.learn.deadbandMs, o.learn.epN, o.learn.rounds.count)) }
        }
        lines.append("echoes ignored \(echoes) · noisy readings \(noisy)")
        writeStatus(lines.joined(separator: "\n"))
        if Date().timeIntervalSince(lastSummary) > 30 { lastSummary = Date(); log("status: \(s) · " + followers.map { "\(outs[$0].name) \(outs[$0].relMs.map { String(format: "%+.1f", $0) } ?? "–")ms rate \(String(format: "%+.2f", outs[$0].rate * 1000))" }.joined(separator: " · ")) }
    }

    func snapshot() -> [String: Any] {
        [ "t": Date().timeIntervalSince1970, "state": lastState, "phase": phase, "sr": sr,
          "debug": ["spots": spots, "tuning": outs[tunerIdx].name, "unknownReads": unknownReads, "prefVelMsPerS": ms(prefVel) / (0.75 * Double(paceDiv)), "probes": probes, "probeMisses": probeMisses, "readings": readingsDone, "relaxed": relaxed, "paceS": 0.25 * Double(paceDiv), "calibrating": calibrating, "w": w, "aggSeq": aggSeq, "micSeq": micSeq, "micTotal": micTotal, "aggHost": aggAnch[aggSeq & 1].0, "micHost": micAnch[micSeq & 1].0],
          "reference": outs[ref].uid, "referencePinned": config.referencePinned == true,
          "totalDelayMs": lastPhys.count == outs.count ? ms(lastPhys[ref] + Double(refHold)) : NSNull(),
          "lockedAt": lockStartedAt.timeIntervalSince1970, "echoes": echoes, "noisy": noisy, "snr": Double(lastSNR), "srcRms": Double(lastSrcRms),
          "devices": outs.enumerated().map { (i, o) -> [String: Any] in
              ["uid": o.uid, "name": o.name, "role": i == ref ? "reference" : "follower", "muted": o.mute,
               "relMs": (i == ref ? 0.0 : o.relMs).map { $0 as Any } ?? NSNull(), "lastErrMs": o.lastErrMs, "holdMs": lagMs(i),
               "driftRateMsPerS": o.rate * 1000, "level": Double(o.level), "fingerprint": i == ref ? 1.0 : o.amp, "latencyMs": lastPhys.count == outs.count ? ms(lastPhys[i]) : NSNull(), "corrections": o.corrections, "hist": o.hist.map { ms($0) },
               "pendingMs": ms(Double(o.pendingFrames)), "slews": o.slews, "snaps": o.snaps,
               "learn": ["window": o.learn.arm.window, "gain": o.learn.arm.gain, "deadbandMs": o.learn.deadbandMs, "jitterMs": o.learn.jitterMs,
                         "roundProgress": o.learn.epN, "rounds": o.learn.rounds.suffix(40).map { ["t": $0.t, "reward": $0.reward, "inSync": $0.inSync, "meanAbsMs": $0.meanAbsMs, "corrections": $0.corrections, "window": o.learn.arms[$0.arm].window, "gain": o.learn.arms[$0.arm].gain] },
                         "arms": o.learn.arms.map { ["window": $0.window, "gain": $0.gain, "n": $0.n, "mean": $0.mean] }] ] },
          "readings": readings, "corrLog": corrLog, "corr": corrSnap.map { Double($0) }, "corrLoMs": -300.0, "corrBinMs": corrBinMs, "spikes": spikesRel ]
    }

    // MARK: corrections
    func apply(_ i: Int, _ err: Double, gain: Double, drift: Bool = true) {
        let o = outs[i], sh = Int64(err * gain)
        // A follower needing to play before its buffer floor means it has become slower than the reference. Earlier
        // versions answered by holding everyone back more, forever; now a small hold-back is allowed up to the cap,
        // and past it the lock re-measures and rebuilds all buffers.
        if abs(sh) > 2205 || sh > 0, (o.meanLag - Double(o.pendingFrames) - Double(sh)) < 3072, refHold + 5120 > maxRefHold {
            log(String(format: "%@ needs to play %.0f ms earlier than its buffer allows; rebuilding buffers", o.name, ms(Double(sh)))); startQuiet("buffers need rebuilding"); return
        }
        func holdBackAll(_ d: Int64) {   // the reference (and so everyone) waits longer
            refHold += d; Pref += Double(d)
            for j in followers where j != i { let q = outs[j]; q.lagT = clampLag(Int64(q.meanLag) + d); q.shiftReq = q.shiftDone; q.rateShift = 0; q.resync = true }
            log(String(format: "hold-back increased by %.0f ms so %@ can play earlier", ms(Double(d)), o.name))
        }
        if abs(sh) > 2205 {
            var target = Int64(o.meanLag) - o.pendingFrames - sh
            if target < 3072 { let d = 5120 - target; holdBackAll(d); target = 5120 }
            o.lagT = clampLag(target); o.shiftReq = o.shiftDone; o.rateShift = 0; o.resync = true; o.corrHist.removeAll()
            corrLog.append(["t": Date().timeIntervalSince1970, "dev": o.uid, "ms": ms(Double(sh)), "kind": "jump"]); o.lastCorrT = nil
        } else {
            let lagAfter = o.meanLag - Double(o.pendingFrames) - Double(sh)
            if sh > 0 && lagAfter < 3072 { holdBackAll(sh + 2048); o.shiftReq -= 2048 } else { o.shiftReq += sh }
            if drift, gain < 1, abs(err) < 0.02 * sr { o.corrHist.append((Date().timeIntervalSince1970, Double(sh))); learnRate(o) }
            o.lastCorrT = Date()
            corrLog.append(["t": Date().timeIntervalSince1970, "dev": o.uid, "ms": ms(err * gain), "kind": "slide"])
        }
        if corrLog.count > 150 { corrLog.removeFirst(corrLog.count - 150) }
        setPace(1); stableSince = nil
        o.corrections += 1; o.learn.epCorr += 1; o.prevErrMs = nil; o.hist.removeAll(); o.pred = 0; clAvg = []; phaseT = Date(); saveMemories()
        log(String(format: "drift: %@ %@ by %.1f ms -> %@", o.name, err > 0 ? "late" : "early", abs(ms(err)), abs(sh) > 2205 ? "jumped" : "sliding"))
    }

    // MARK: the loop (every 0.75 s)
    func tick() {
        // Each speaker now has its own level (menu bar → Levels, or its buttons). Followers play at full digital
        // level unless the reference is muted. (The old volumeGain() trusted the dB property, which these speakers report as
        // ~0 dB at any level, so followers were already at full level; this keeps that and drops the misleading code.)
        followerGain = 1   // each speaker has its own level now; a reference at 0% must not silence the others (2026-11-15)
        updateLevels()
        if FileManager.default.fileExists(atPath: relockURL.path) { try? FileManager.default.removeItem(at: relockURL); startLock() }
        for (i, o) in outs.enumerated() where o.gaps != o.gapsSeen { o.gapsSeen = o.gaps; requestRecal(i, "\(o.name)'s audio stream was interrupted") }
        if phase == "spot", Date().timeIntervalSince(spotStart) > 25 { for o in outs { o.trim = 1 }; phase = "track"; log("level check: no clear readings, gave up"); }
        if phase == "loud", Date().timeIntervalSince(loudStart) > 12 { log("calibrating: no clear music to measure loudness"); finishLock(); return }
        if let why = recalReq, Date().timeIntervalSince(lockStartedAt) > 3, phase != "scan" {
            recalReq = nil; startQuiet(why); return
        }
        if outs.contains(where: { abs($0.pendingFrames) > 64 }) || refNudgeReq != refNudgeDone { phaseT = Date(); status(phase == "scan" ? "re-locking quietly (nudging \(outs[scanIdx].name))" : "adjusting…"); return }
        // wait until the mic window holds only audio played after the last change: window + output latency (~0.7 s)
        let tracking = phase == "track" || phase == "probe" || phase == "spot" || phase == "scan"
        N = tracking ? 32768 : 65536
        if Date().timeIntervalSince(phaseT) < (tracking ? 1.5 : 2.3) { return }
        // adaptive pace: once everything has been in time for 60 s, measure every other tick (1.5 s)
        tickN += 1
        if phase == "track" && paceDiv > 1 && tickN % paceDiv != 0 { return }
        guard let rms = grab() else {
            if w == 0 && Date().timeIntervalSince(startedAt) > 15 {
                if !tapStallLogged { tapStallLogged = true; log("capture not started yet: macOS hasn't begun delivering system audio to the tap. It usually starts once something plays; if it never does, remove and re-allow SpeakerSync under Screen & System Audio Recording") }
                status("waiting for macOS to start audio capture (play something)"); return
            }
            status("collecting audio…"); return }
        if rms < 0.003 { status(phase == "track" ? "locked, holding (music quiet or paused)" : "calibrating: waiting for the next sweep"); return }
        // while tracking only lags within ±350 ms of the reference matter; the lock needs the full 0–1.1 s
        let span = phase == "scan" ? Int(0.5 * sr) : Int(0.35 * sr)   // a stream restart can move a speaker up to ~230 ms
        let wide = phase == "solo" || phase == "loud", wlo = wide ? 0 : max(0, Int(Pref) - span), whi = wide ? maxLag : min(maxLag, Int(Pref) + span)
        mWin.withUnsafeBufferPointer { mp in sWin.withUnsafeBufferPointer { sp in gccPhat(mp.baseAddress!, N, sp.baseAddress!, N + maxLag, sr: sr, maxLag: maxLag, lo: wlo, hi: whi, into: &clRaw) } }
        var rmax: Float = 1e-12; for i in wlo...whi { rmax = max(rmax, clRaw[i]) }
        if clAvg.count != clRaw.count || phase != "track" { clAvg = [Float](repeating: 0, count: clRaw.count); for i in wlo...whi { clAvg[i] = clRaw[i] / rmax } }
        else { for i in wlo...whi { clAvg[i] = 0.6 * clAvg[i] + 0.4 * clRaw[i] / rmax } }
        let cl = clAvg
        var finite = true; for i in wlo...whi where !cl[i].isFinite { finite = false; break }
        guard finite else { clAvg = []; status("collecting audio…"); return }
        let noise = noiseFloor(cl, wlo, whi)
        let (gL, gV) = argmax(cl, wlo, whi)
        lastSNR = gV / noise; lastSrcRms = rms; readingsDone += 1
        snapshotCorr(cl, center: phase == "track" || phase == "probe" ? Int(Pref) : gL, gV: gV)

        switch phase {
        case "solo":
            guard gV > 8 * noise else { status("calibrating: can't hear \(outs[soloIdx].name) clearly (\(Int(min(gV / noise, 1e6)))×)"); return }
            let o = outs[soloIdx]
            if let c = o.soloCand, abs(c - Double(gL)) < 0.001 * sr { o.soloP = Double(gL) } else { o.soloCand = Double(gL); status("calibrating: confirming \(o.name)"); return }
            o.soloSNR = Double(gV / noise)
            log(String(format: "lock: %@ heard at %.1f ms (%.0f× noise)", o.name, ms(Double(gL)), gV / noise))
            soloIdx += 1
            if soloIdx < outs.count { setSolo(soloIdx); return }
            startLoudness()
        case "loud":
            // music solo for the loudness fingerprint only; timing already came from the sweep. Its music spike sits
            // within a few ms of the sweep spike (measured 4–14 ms), so look ±20 ms around it.
            let o = outs[loudIdx], c = Int(o.soloP ?? Double(gL)), r = Int(0.02 * sr)
            let (_, v) = argmax(cl, c - r, c + r)
            guard v > 6 * noise else { status("calibrating: measuring how loud \(o.name) is (needs music)"); return }
            loudSNR[loudIdx] = Double(v / noise)
            loudIdx += 1
            if loudIdx < outs.count { setSolo(loudIdx); return }
            finishLock()
        case "scan":
            guard gV > 6 * noise else { status("re-locking quietly (waiting for a clear reading)"); return }
            scanStep(cl, noise: noise, lo: wlo, hi: whi)
        case "spot":
            guard gV > 6 * noise, let r = spotRatio(cl) else { status("checking which speaker is off (waiting for a clear reading)"); return }
            if spotStep == 0 { spotBase = r } else { spotRel.append(r) }
            spotStep += 1
            if spotStep <= outs.count { setSpotlight(spotStep - 1); status("checking which speaker is off (subtle level check)"); return }
            finishSpot()
        case "probe":
            // the candidate was slid `nudge` frames later: if it owns the spike, the spike moved by the same amount
            let x = Int(Pref + probeX), rad = Int(0.003 * sr)
            let (_, vOld) = argmax(cl, x - rad, x + rad), (_, vNew) = argmax(cl, x - Int(nudge) - rad, x - Int(nudge) + rad)   // slid 10 ms earlier
            let moved = vNew >= 0.3 * gV && vNew > 6 * noise && vOld < 0.3 * gV
            let j = probeQueue[probeIdx], o = outs[j]
            probes += 1
            if moved {
                log(String(format: "probe: the %+.1f ms spike is %@ (moved when nudged)", ms(probeX), o.name))
                phase = "track"; unexplained = []; let e = probeX - Double(nudge); apply(j, e, gain: abs(e) > 0.05 * sr ? 1 : 0.6, drift: false)
            } else {
                o.shiftReq -= nudge   // undo
                if probeIdx + 1 < probeQueue.count { probeIdx += 1; outs[probeQueue[probeIdx]].shiftReq += nudge; phaseT = Date(); status("identifying a drifting output") }
                else {
                    probeMisses += 1; phase = "track"; unexplained = []; phaseT = Date()
                    // A strong spike far from the reference that no follower owns is almost certainly the reference itself
                    // after a Bluetooth buffer jump (the Brane jumped +130 ms on 2026-11-14 and the tracker quietly latched
                    // onto the followers). Nudges can't move the reference, so re-calibrate with sweeps instead of calling it
                    // a reflection. Real reflections seen here sit within ±20 ms.
                    // Level spotlight disabled (2026-11-14 slip test): a 3 dB dip changes a spike ~30%, but spike heights swing
                    // 0.3–2× reading to reading with the music, so it named the wrong owner (moved the JBL 59 ms for a Brane
                    // spike, dismissed the Brane's +100 ms spikes as reflections). Timing nudges identify followers reliably,
                    // so pin a steady speaker as the reference and send unowned far spikes to a sweep re-calibration.
                    if useSpotlight && Date().timeIntervalSince(lastSpot) > 6 && Date().timeIntervalSince(lockStartedAt) > 8 {
                        startSpot(probeX)
                    } else if abs(ms(probeX)) > 25 && Date().timeIntervalSince(lockStartedAt) > 20 {
                        recalReq = String(format: "a strong %+.0f ms spike belongs to no follower, so the reference's own delay has probably jumped", ms(probeX)); suspectSpike = probeX
                    } else { log(String(format: "probe: couldn't match the %+.1f ms spike to an output; ignoring it as a reflection for 60 s", ms(probeX))); noteReflection(probeX) }
                }
            }
        default:
            track(cl, noise: noise, gV: gV, gL: gL)
        }
    }

    /// After the sweeps: sanity-check them, then switch the ring back to music and play each output alone on music
    /// briefly to learn its loudness fingerprint. A sweep can't give one: PHAT whitening scores a clean sweep near the
    /// maximum on every speaker (all clamped to 3.00), and wrong fingerprints swapped followers' identities in the
    /// 2026-11-14 A/B (55 alternating corrections in 5 min vs 0–8 for iteration 9).
    func startLoudness() {
        let phys = outs.indices.map { (outs[$0].soloP ?? 0) - (Double(lagFrames($0))) }
        if let bad = outs.indices.first(where: { phys[$0] < -0.01 * sr || phys[$0] > 0.9 * sr }), lockRetries < 3 {
            lockRetries += 1
            log(String(format: "lock: %@ reading implies %.0f ms of latency, impossible; listening again", outs[bad].name, ms(phys[bad])))
            outs[bad].soloP = nil; outs[bad].soloCand = nil; soloIdx = bad; setSolo(bad); return
        }
        // back to music: blank the last 2 s of ring so no output plays a leftover sweep
        calibrating = false
        let W = w; for p in max(0, W - Int64(2 * sr))..<W { let j = Int(p) & mask; ring[j * 2] = 0; ring[j * 2 + 1] = 0 }
        loudSNR = [Double](repeating: 0, count: outs.count); loudIdx = 0; loudStart = Date()
        phase = "loud"; setSolo(0); status("calibrating: measuring loudness")
    }

    func finishLock() {
        // physical delay of each output = where its spike was minus the buffer lag we gave it
        let phys = outs.indices.map { (outs[$0].soloP ?? 0) - (Double(lagFrames($0))) }
        // a real output's latency (Bluetooth or wired, incl. the mic path) is 0–900 ms; anything else was a wrong spike
        if let bad = outs.indices.first(where: { phys[$0] < -0.01 * sr || phys[$0] > 0.9 * sr }), lockRetries < 3 {
            lockRetries += 1
            log(String(format: "lock: %@ reading implies %.0f ms of latency, impossible; listening again", outs[bad].name, ms(phys[bad])))
            outs[bad].soloP = nil; outs[bad].soloCand = nil; soloIdx = bad; setSolo(bad); phase = "solo"; return
        }
        // Did the far-spike re-calibration find a real jump? If no output's own delay moved more than 8 ms, the spike was a
        // room reflection (seen at ±26–30 ms on 2026-11-14, just outside the 25 ms rule): remember it for the session.
        if let sp = suspectSpike, lastPhys.count == phys.count {
            let moved = phys.indices.map { abs(ms(phys[$0] - lastPhys[$0])) }.max() ?? 0
            if moved < 8 { reflections.append(sp); log(String(format: "lock: nothing moved (max %.1f ms), so the %+.0f ms spike is a room reflection; ignoring it from now on", moved, ms(sp))) }
            else { log(String(format: "lock: confirmed a real jump (an output's delay moved %.0f ms)", moved)) }
        }
        suspectSpike = nil; lastPhys = phys
        let slowest = phys.indices.max { phys[$0] < phys[$1] }!
        if config.referencePinned != true, slowest != ref, ms(phys[slowest] - phys[ref]) > 20 {
            log(String(format: "lock: %@ is the slowest output (%.0f ms behind %@), making it the reference", outs[slowest].name, ms(phys[slowest] - phys[ref]), outs[ref].name))
            config.reference = outs[slowest].uid; saveConfig(); restartRequested = true; return
        }
        // Rebuild every buffer from scratch: everything plays at T = the slowest output's latency + minimal headroom,
        // so total delay is the reference's own latency + ~46 ms, and nothing from earlier locks accumulates.
        let target = outs[ref].soloP ?? 0, hold0 = refHold
        let T = max(phys[ref] + 2048, followers.map { phys[$0] + minFollowerLag }.max() ?? 0)
        refHold = min(maxRefHold, Int64(T - phys[ref]))
        Pref = target + Double(refHold - hold0)
        for i in followers { let o = outs[i]; o.lagT = clampLag(Int64(T - phys[i])); o.shiftReq = o.shiftDone; o.rateShift = 0; o.resync = true
            log(String(format: "lock: %@ was %+.1f ms vs %@ (buffer %.0f ms)", o.name, ms((o.soloP ?? target) - target), outs[ref].name, ms(Double(o.lagT)))) }
        log(String(format: "lock: reference hold-back %.0f ms; total delay from the Mac ≈ %.0f ms (the reference's own latency + hold-back)", ms(Double(refHold)), ms(phys[ref] + Double(refHold))))
        // The fingerprint is compared against music spikes, and a sweep's loudness ratio isn't the same thing (it gave
        // Eris 2.42 / JBL 3.00 where music had shown 0.36 / 1.70). Use the music-learned value for this setup when there is one.
        // loudness fingerprint: measured on music now if possible, else this setup's saved one, else neutral (learned while tracking)
        let measured = loudSNR.count == outs.count && loudSNR.allSatisfy { $0 > 0 }
        var source = "measured on music"
        for i in followers {
            let o = outs[i]
            if measured { o.amp = max(0.1, min(3, loudSNR[i] / loudSNR[ref])); o.ampLearned = true }
            else if let a = loadMem(o.uid).amps?[setupKey] { o.amp = a; o.ampLearned = true; source = "saved (no music to measure)" }
            else { o.amp = 1; o.ampLearned = false; source = "neutral (no music yet; learning)" }
        }
        log("lock: loudness fingerprint (\(source)) " + followers.map { String(format: "%@ %.2f", outs[$0].name, outs[$0].amp) }.joined(separator: ", "))
        calibrating = false
        unmuteAll(); phase = "track"; phaseT = Date(); saveMemories(); status("locked")
    }
    func lagFrames(_ i: Int) -> Int64 { i == ref ? refHold + refNudgeDone : Int64(outs[i].meanLag) }

    func snapshotCorr(_ cl: [Float], center: Int, gV: Float) {
        let halfW = Int(0.3 * sr), bins = 600, lo = center - halfW, per = max(1, (2 * halfW) / bins)
        var snap = [Float](repeating: 0, count: bins)
        for b in 0..<bins { var m: Float = 0; for k in 0..<per { let L = lo + b * per + k; if L >= 0 && L < cl.count { m = max(m, cl[L]) } }; snap[b] = m / max(gV, 1e-12) }
        corrSnap = snap; corrBinMs = ms(Double(per))
    }

    func track(_ cl: [Float], noise: Float, gV: Float, gL: Int) {
        // reference spike: slew-limited so a louder nearby output can't drag it
        let er = Int(0.012 * sr)
        let (eL, eV) = argmax(cl, Int(Pref) - er, Int(Pref) + er)
        // α-β tracker: a learned velocity follows steady clock drift between the capture and the mic (~0.5 ms/s
        // with a Bluetooth clock); the slew-limited correction still stops a louder nearby spike from dragging it.
        Pref += prefVel
        refHeard = eL >= 0 && eV >= 0.15 * gV && eV > 5 * noise
        if refHeard {
            let e = Double(eL) - Pref, st = 0.00005 * sr
            Pref += max(-st, min(st, 0.1 * e))
            prefVel = max(-0.0015 * sr, min(0.0015 * sr, prefVel + 0.008 * e))   // ≤ ±1.5 ms per reading
            lostRef = 0
        } else {
            // lost the reference: if the strongest spike has held still somewhere else for 8 readings, re-anchor there
            if let lg = lastGL, abs(gL - lg) < Int(0.002 * sr) { lostRef += 1 } else { lostRef = 1 }
            // Never re-anchor on the strongest spike: with a quiet reference that is another speaker, and the tracker then reads
            // "in time" while the reference is off (2026-11-14 Brane, 2026-11-15 Eris at 0%). Find the reference by nudging it.
            if lostRef >= 8 { lostRef = 0; if (outs[ref].level) > 0.02 { requestRecal(ref, "can't hear the reference (\(outs[ref].name)) where it should be") } }
        }
        lastGL = gL
        // other spikes within ±300 ms, strongest first, minus echoes
        let rad = Int(0.3 * sr), ex = Int(0.002 * sr)
        var excl: [ClosedRange<Int>] = [(Int(Pref) - ex)...(Int(Pref) + ex)], spikes: [Int] = [], spikeV: [Double] = []
        for _ in 0..<(followers.count + 2) {
            let (L, v) = argmax(cl, Int(Pref) - rad, Int(Pref) + rad, excl: excl)
            guard L >= 0, v >= 0.3 * gV, v > 6 * noise else { break }
            excl.append((L - Int(0.003 * sr))...(L + Int(0.003 * sr)))
            let (pL, pV) = argmax(cl, L - Int(0.012 * sr), L - Int(0.003 * sr))
            if pL >= 0 && v < 0.5 * pV { echoes += 1; continue }
            spikes.append(L); spikeV.append(Double(v))
        }
        let clear = gV > 6 * noise
        // Without the reference's own spike, "no stray spike" proves nothing: report it, don't score it as in time.
        if !refHeard {
            for j in followers { outs[j].relMs = nil }
            status(outs[ref].level >= 0 && outs[ref].level <= 0.02 ? "can't verify sync: the reference (\(outs[ref].name)) is at 0% volume. Raise it or pick another reference" : "can't hear the reference (\(outs[ref].name)); timing unverified")
            return
        }
        if !clear { noisy += 1; status("holding, room too noisy for a clear reading"); return }
        let rels = spikes.map { Double($0) - Pref }
        spikesRel = rels.map { ["relMs": ms($0)] }
        // match spikes to outputs
        var errs: [Int: Double] = [:], used = Set<Int>()
        if followers.count == 1 { if let r = rels.first { errs[followers[0]] = r; used.insert(0) } }
        else {
            // identity = where each output was expected (pred) + how loud its spike is (amp). Two near-equal candidates -> ambiguous (nudge later).
            let refV = max(Double(eV), 1e-6)
            for (si, r) in rels.enumerated() {
                let h = spikeV[si] / refV
                let cands = followers.filter { errs[$0] == nil && abs(outs[$0].pred - r) < 0.015 * sr }
                    .map { j -> (Int, Double) in (j, abs(outs[j].pred - r) / (0.015 * sr) + abs(log(h / outs[j].amp))) }.sorted { $0.1 < $1.1 }
                guard let best = cands.first else { continue }
                if cands.count > 1 && cands[1].1 - best.1 < 0.3 { continue }
                errs[best.0] = r; used.insert(si)
                outs[best.0].amp = max(0.1, min(3, 0.9 * outs[best.0].amp + 0.1 * h)); outs[best.0].ampLearned = true
            }
        }
        // Honest accounting: assigned = known error; no stray spike anywhere near = merged (truly in time);
        // a stray spike near it that couldn't be attributed = unknown (not scored, not learned from).
        let strays = rels.enumerated().filter { !used.contains($0.offset) }.map { (r: $0.element, v: spikeV[$0.offset]) }
        let refH = max(Double(eV), 1e-6)
        for j in followers {
            let o = outs[j]
            // a stray can only be this output if it is at least half as tall as this output's spike would be (loudness fingerprint)
            // ...and identity only matters if that stray is outside the in-time band: within it, whoever it is, they're in time
            let unknown = errs[j] == nil && strays.contains { abs(ms($0.r)) > o.learn.deadbandMs && abs($0.r - o.pred) < 0.03 * sr && $0.v >= 0.5 * o.amp * refH && !isReflection($0.r) }
            if unknown {
                unknownReads += 1; o.relMs = nil
                readings.append(["t": Date().timeIntervalSince1970, "dev": o.uid, "err": ms(o.pred), "valid": false, "unknown": true])
                continue
            }
            let e = errs[j] ?? 0
            o.relMs = ms(e); o.lastErrMs = ms(e); o.pred = e
            o.hist.append(e); if o.hist.count > max(o.learn.arm.window, settle) { o.hist.removeFirst() }
            // jitter only from consecutive attributed readings: "merged" readings are an assumed 0 and made the
            // 3-output jitter look tiny (0.7 ms), pinning the in-time band at its 4 ms floor
            let attributed = errs[j] != nil
            o.learn.observe(errMs: ms(e), prevMs: attributed ? o.prevErrMs : nil, corrected: false); o.prevErrMs = attributed ? ms(e) : nil
            let explore = followers.count == 1 || j == tunerIdx
            if let line = o.learn.maybeEndRound(explore: explore) {
                log("learning \(o.name): " + line)
                if explore && followers.count > 1 { tuner += 1; log("tuning: \(outs[tunerIdx].name) explores next; the others hold their best settings") }
                saveMemories()
            }
            readings.append(["t": Date().timeIntervalSince1970, "dev": o.uid, "err": ms(e), "valid": errs[j] != nil, "unknown": false])
        }
        if readings.count > 600 { readings.removeFirst(readings.count - 600) }
        // a spike nobody owns (3+ outputs): identify it with a probe once it has lasted
        // Probes mute a speaker for ~2 s, so only chase strong, persistent spikes, at most one probe per 20 s,
        // and treat a spike a probe couldn't match as a reflection for 60 s.
        let orphans = rels.enumerated().filter { !used.contains($0.offset) }.map { $0.element }
        deadSpikes.removeAll { Date().timeIntervalSince($0.1) > 60 }
        let band = followers.map { outs[$0].learn.deadbandMs }.max() ?? 6
        let strong = orphans.filter { r in abs(ms(r)) > band && cl[max(0, min(cl.count - 1, Int(Pref + r)))] >= 0.5 * gV && !isReflection(r) }
        if followers.count > 1 {
            unexplained.append(strong.first ?? .nan); if unexplained.count > 6 { unexplained.removeFirst() }
        }
        if followers.count > 1, let o = strong.first {
            let near = unexplained.filter { abs($0 - o) < 0.004 * sr }
            if near.count >= 3, Date().timeIntervalSince(lastProbe) > 2 {   // nudges are inaudible, so resolve ambiguity quickly
                lastProbe = Date()
                probeX = near.sorted()[near.count / 2]; probeQueue = followers.sorted { abs(outs[$0].pred) < abs(outs[$1].pred) }; probeIdx = 0
                outs[probeQueue[0]].shiftReq += nudge; phase = "probe"; phaseT = Date(); status("identifying a drifting output"); return
            }
        }
        // Decision. At 0.25 s readings on a 0.75 s window each reading is noisier, and correcting on a 3-reading median
        // (0.75 s) made the JBL hunt: 8 corrections, 3 direction flips in 75 s (2026-11-15). Now:
        //  · a real jump (> 25 ms) seen at the same place in 3 readings in a row (0.75 s) is fixed at once;
        //  · anything smaller is fixed only when every reading for ~1.5 s sits on the same side, at least half the band
        //    out, and the median is outside the band. Noise flips sides, a real slip doesn't.
        for j in followers {
            let o = outs[j]; guard o.hist.count >= 3 else { continue }
            let last3 = Array(o.hist.suffix(3)), m3 = last3.sorted()[1]
            if abs(ms(m3)) > 25, last3.max()! - last3.min()! < 0.003 * sr {
                apply(j, m3, gain: 1); status("correcting \(o.name)"); return
            }
            guard o.hist.count >= max(o.learn.arm.window, settle) else { continue }
            let med = o.hist.sorted()[o.hist.count / 2], db = o.learn.deadbandMs
            let oneSide = o.hist.allSatisfy { ($0 > 0) == (med > 0) && abs(ms($0)) >= 0.5 * db }
            if abs(ms(med)) >= db && oneSide { apply(j, med, gain: abs(med) > 0.05 * sr ? 1 : max(0.85, o.learn.arm.gain)); status("correcting \(o.name)"); return }   // confirmed over 1.5 s, so fix (nearly) all of it: 40% couldn't keep up with a creeping Brane
        }
        let allIn = followers.allSatisfy { abs(outs[$0].relMs ?? 0) <= outs[$0].learn.deadbandMs }
        if allIn {
            if stableSince == nil { stableSince = Date() }
            let held = Date().timeIntervalSince(stableSince!)
            _ = held   // live system: never slow down when calm (a slip must be caught as it starts, not on the next slow tick)
        } else { stableSince = nil; setPace(1, "an output left the in-time band") }
        status(allIn ? (relaxed ? "locked, in time (relaxed pace)" : "locked, in time") : "locked, watching")
    }
}
var restartRequested = false

// MARK: - live dashboard server (loopback only): http://localhost:8765
final class Web {
    var listener: NWListener?
    init() {
        let params = NWParameters.tcp; params.requiredInterfaceType = .loopback; params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: 8765) else { log("web: could not listen on 8765"); return }
        l.newConnectionHandler = { c in c.start(queue: .main); Web.handle(c) }
        l.start(queue: .main); listener = l; log("live dashboard at http://localhost:8765")
    }
    static func handle(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let parts = (req.split(separator: "\r\n").first ?? "").split(separator: " ")
            let path = (parts.count > 1 ? String(parts[1]) : "/").split(separator: "?").first.map(String.init) ?? "/"
            var body = Data(), type = "application/json"
            switch path {
            case "/status.json":
                let obj: [String: Any] = engine?.snapshot() ?? ["t": Date().timeIntervalSince1970, "state": waitingFor.isEmpty ? "starting" : waitingFor, "phase": "idle", "devices": [Any]()]
                body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            case "/log":
                type = "text/plain; charset=utf-8"
                let lines = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n")
                body = Data(lines.suffix(160).joined(separator: "\n").utf8)
            case "/slip":   // test hook: /slip?i=<output index>&ms=<shift> moves an output without telling the tracker
                let q = Dictionary(uniqueKeysWithValues: ((parts.count > 1 ? String(parts[1]) : "").split(separator: "?").dropFirst().first ?? "").split(separator: "&").compactMap { kv -> (String, String)? in let p = kv.split(separator: "="); return p.count == 2 ? (String(p[0]), String(p[1])) : nil })
                if let i = q["i"].flatMap(Int.init), let v = q["ms"].flatMap(Double.init) { DispatchQueue.main.async { engine?.injectSlip(i, v) } }
                body = Data("{\"ok\":true}".utf8)
            case "/relock":
                FileManager.default.createFile(atPath: relockURL.path, contents: nil); body = Data("{\"ok\":true}".utf8)
            default:
                type = "text/html; charset=utf-8"
                body = (try? Data(contentsOf: dir.appendingPathComponent("live.html"))) ?? Data("<h1>live.html missing</h1>".utf8)
            }
            var out = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            out.append(body); c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

// MARK: - lifecycle
var engine: Engine? = nil
var waitingFor = "", cooldown = Date.distantPast
func stopEngine() { engine?.saveMemories(); engine?.teardown(); engine = nil }
func check() {
    if restartRequested { restartRequested = false; stopEngine() }
    let (s, why) = currentSetup()
    if let e = engine { if s != e.setup { log("change: \(why == "ok" ? "outputs or mic changed" : why)"); stopEngine(); waitingFor = "" } else { return } }
    guard let s else { if why != waitingFor { waitingFor = why; log("idle: \(why)"); writeStatus("state: idle, \(why)") }; menu?.refreshIcon(); return }
    guard Date() > cooldown else { return }
    waitingFor = ""
    engine = Engine(s)
    if engine == nil { cooldown = Date().addingTimeInterval(10); writeStatus("state: start failed, retrying in 10 s (see log)") }
    menu?.refreshIcon()
}

// MARK: - menu bar
final class Menu: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    override init() {
        super.init()
        menu.delegate = self; item.menu = menu
        refreshIcon()
    }
    func refreshIcon() {
        let locked = engine?.lastState.hasPrefix("locked") ?? false
        let name = engine == nil ? "hifispeaker.2" : (locked ? "hifispeaker.2.fill" : "hifispeaker.2")
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "SpeakerSync"); img?.isTemplate = true
        item.button?.image = img
        item.button?.appearsDisabled = engine == nil
    }
    func add(_ title: String, _ sel: Selector?, _ rep: Any? = nil, on: Bool = false, enabled: Bool = true, to m: NSMenu? = nil) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; i.representedObject = rep
        i.state = on ? .on : .off; i.isEnabled = enabled && (sel != nil); (m ?? menu).addItem(i)
    }
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if let e = engine {
            add(e.lastState.isEmpty ? "Starting" : e.lastState.prefix(1).uppercased() + e.lastState.dropFirst(), nil)
            for (i, o) in e.outs.enumerated() {
                let detail = i == e.ref ? "reference" : (o.relMs.map { abs($0) <= 6 ? String(format: "in time (%+.1f ms)", $0) : String(format: "%+.1f ms", $0) } ?? "measuring")
                add("   \(o.name): \(detail)", nil)
            }
        } else { add(waitingFor.isEmpty ? "Starting" : waitingFor.prefix(1).uppercased() + waitingFor.dropFirst(), nil) }
        if let e = engine {
            m.addItem(.separator()); add("Levels", nil)
            levelIDs = e.outs.map { $0.id }
            for (k, o) in e.outs.enumerated() {
                let v = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 24))
                let l = NSTextField(labelWithString: String(o.name.prefix(14))); l.frame = NSRect(x: 18, y: 4, width: 96, height: 16); l.font = .menuFont(ofSize: 12)
                let sl = NSSlider(value: Double(hwLevel(o.id) ?? 0), minValue: 0, maxValue: 1, target: self, action: #selector(setLevel(_:)))
                sl.frame = NSRect(x: 116, y: 2, width: 140, height: 20); sl.tag = k; sl.isContinuous = true; sl.controlSize = .small
                v.addSubview(l); v.addSubview(sl)
                let it = NSMenuItem(); it.view = v; m.addItem(it)
            }
        }
        m.addItem(.separator())
        let outsMenu = NSMenu(); let outsItem = NSMenuItem(title: "Outputs to sync", action: nil, keyEquivalent: ""); outsItem.submenu = outsMenu; m.addItem(outsItem)
        // Reference speaker: the one everything is timed against (and the clock). Pick a steady one: a speaker whose own delay
        // jumps (the Brane) is hard to follow as the reference, but easy to catch as a follower.
        let refMenu = NSMenu(); let refItem = NSMenuItem(title: "Reference speaker", action: nil, keyEquivalent: ""); refItem.submenu = refMenu; m.addItem(refItem)
        add("Automatic (slowest)", #selector(pickReference(_:)), nil, on: config.referencePinned != true, to: refMenu)
        for d in pickableOutputs() where config.outputs.contains(d.uid) { add(d.name, #selector(pickReference(_:)), d.uid, on: config.referencePinned == true && config.reference == d.uid, to: refMenu) }
        for d in pickableOutputs() { add(d.name, #selector(toggleOutput(_:)), d.uid, on: config.outputs.contains(d.uid), to: outsMenu) }
        let micMenu = NSMenu(); let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: ""); micItem.submenu = micMenu; m.addItem(micItem)
        add("Built-in (automatic)", #selector(pickMic(_:)), nil, on: config.mic == nil, to: micMenu)
        for d in pickableInputs() { add(d.name, #selector(pickMic(_:)), d.uid, on: config.mic == d.uid, to: micMenu) }
        m.addItem(.separator())
        add("Re-lock speakers", engine != nil ? #selector(relock) : nil)
        add("Open live dashboard", #selector(openDashboard))
        add(config.paused ? "Resume syncing" : "Pause syncing", #selector(togglePause))
        m.addItem(.separator())
        add("Quit SpeakerSync", #selector(quit))
    }
    @objc func toggleOutput(_ s: NSMenuItem) {
        guard let uid = s.representedObject as? String else { return }
        if let i = config.outputs.firstIndex(of: uid) { config.outputs.remove(at: i) } else { config.outputs.append(uid) }
        if let r = config.reference, !config.outputs.contains(r) { config.reference = nil }
        saveConfig(); log("outputs: \(config.outputs.count) chosen"); check()
    }
    var levelIDs: [AudioObjectID] = []
    @objc func setLevel(_ s: NSSlider) { guard s.tag < levelIDs.count else { return }; setHwLevel(levelIDs[s.tag], Float(s.doubleValue)) }
    @objc func pickReference(_ s: NSMenuItem) {
        if let uid = s.representedObject as? String { config.reference = uid; config.referencePinned = true } else { config.referencePinned = nil }
        saveConfig(); log("reference: " + (config.referencePinned == true ? "pinned to \(s.title)" : "automatic (slowest output)")); restartRequested = true; check()
    }
    @objc func pickMic(_ s: NSMenuItem) { config.mic = s.representedObject as? String; saveConfig(); check() }
    @objc func relock() { engine?.startLock() }
    @objc func openDashboard() { NSWorkspace.shared.open(URL(string: "http://localhost:8765")!) }
    @objc func togglePause() { config.paused.toggle(); saveConfig(); check() }
    @objc func quit() { stopEngine(); writeStatus("state: stopped"); NSApp.terminate(nil) }
}
var menu: Menu? = nil

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
AVCaptureDevice.requestAccess(for: .audio) { ok in log("microphone permission: \(ok)") }
log("SpeakerSync v3 launched")
let web = Web()
menu = Menu()
var devAddr = A(kAudioHardwarePropertyDevices)
AudioObjectAddPropertyListenerBlock(sys, &devAddr, DispatchQueue.main) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { check() } }
var sigs: [DispatchSourceSignal] = []
for s in [SIGTERM, SIGINT, SIGHUP] {
    signal(s, SIG_IGN); let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
    src.setEventHandler { stopEngine(); writeStatus("state: stopped"); exit(0) }; src.resume(); sigs.append(src)
}
check()
var ticks = 0
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    ticks += 1; if ticks % 4 == 0 || restartRequested { check() }
    engine?.tick(); if ticks % 2 == 0 { menu?.refreshIcon() }
}
app.run()
