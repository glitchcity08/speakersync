// Per-output identification ("watermark") codes and the detection math, shared by SyncProbe and SpeakerSync.
//
// Idea: each output gets its own pseudo-random noise code mixed far below the music. Correlating the mic
// against one output's code finds only that output's spike, so identity no longer depends on loudness.
// Merge path into SpeakerSync: give each Out a `WatermarkCode(seed:)`, add `code.sample(at: position) * level`
// in its IOProc, and call `SSCorrelator.detect(code:…)` per output each reading instead of guessing identity.
import Foundation
import Accelerate

/// A deterministic, roughly white noise code with unit RMS, high-passed to stay out of the bass. Loops cyclically.
public struct WatermarkCode {
    public let seed: UInt64
    public let samples: [Float]
    public var length: Int { samples.count }
    public init(seed: UInt64, length: Int) {
        self.seed = seed
        var s = seed &* 0x9E3779B97F4A7C15 | 1, prev: Float = 0, out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17                   // xorshift64
            let u = Float(Double(s >> 11) / Double(1 << 53)) * 2 - 1    // uniform -1…1
            out[i] = u - 0.95 * prev; prev = u                          // gentle high-pass (removes rumble)
        }
        var rms: Float = 0; vDSP_rmsqv(out, 1, &rms, vDSP_Length(length))
        samples = out.map { $0 / max(rms, 1e-9) }
    }
    @inline(__always) public func sample(at i: Int) -> Float { samples[((i % length) + length) % length] }
}

public enum SSDSP {
    /// Power of one frequency in a block (Goertzel), normalised per sample.
    public static func goertzelPower(_ x: UnsafeBufferPointer<Float>, freq: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * freq / sampleRate, c = 2 * cos(w); var s1 = 0.0, s2 = 0.0
        for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
        return max(0, s1 * s1 + s2 * s2 - c * s1 * s2) / Double(max(1, x.count * x.count))
    }
    /// Linear resampling of `x` (rate `from`) starting at fractional index `start`, producing `count` samples at rate `to`.
    public static func resample(_ x: UnsafeBufferPointer<Float>, start: Double, from: Double, to: Double, count: Int) -> [Float] {
        var y = [Float](repeating: 0, count: count); let step = from / to
        for k in 0..<count {
            let p = start + Double(k) * step, i = Int(floor(p)), f = Float(p - floor(p))
            guard i >= 0, i + 1 < x.count else { continue }
            y[k] = x[i] + (x[i + 1] - x[i]) * f
        }
        return y
    }
}

/// GCC-PHAT-β correlator with reusable buffers (one per FFT size). Same weighting SpeakerSync's engine uses.
public final class SSCorrelator {
    public let log2n: vDSP_Length, n: Int, half: Int
    private let setup: FFTSetup
    private var a: [Float], aRe: [Float], aIm: [Float], bRe: [Float], bIm: [Float], out: [Float]
    public init(log2n: Int) {
        self.log2n = vDSP_Length(log2n); n = 1 << log2n; half = n / 2
        setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
        a = .init(repeating: 0, count: n); aRe = .init(repeating: 0, count: half); aIm = aRe; bRe = aRe; bIm = aRe; out = a
    }
    deinit { vDSP_destroy_fftsetup(setup) }
    private func fft(_ x: [Float], _ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<n { a[i] = i < x.count ? x[i] : 0 }
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            a.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &sc, 1, vDSP_Length(half)) }
            vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD)) } }
    }
    /// |c(L)| for L in 0...maxLag where c(L) = Σ code[n]·rec[n+L]: how many samples the code arrives late in the recording.
    /// Use beta 0 (plain correlation) for codes hidden below the music: whitening (beta > 0) spreads weight evenly over
    /// frequency bins, and a buried code is pure noise in every single bin, so whitening destroys its processing gain.
    /// (Tested 2026-11-14: a 2 s code is only detectable ~30 dB below the room even then.) Use beta 0.75 for the music itself.
    public func correlate(code: [Float], recording: [Float], sampleRate: Double, band: (Double, Double) = (300, 20000), beta: Float = 0, maxLag: Int) -> [Float] {
        fft(code, &aRe, &aIm); fft(recording, &bRe, &bIm)
        let binHz = sampleRate / Double(n), lo = max(1, Int(band.0 / binHz)), hi = min(half - 1, Int(band.1 / binHz))
        var re = [Float](repeating: 0, count: half), im = re, p = beta / 2
        for k in lo...hi {   // conj(code) · recording, PHAT-β whitened
            let ar = aRe[k], ai = -aIm[k], br = bRe[k], bi = bIm[k]
            let x = ar * br - ai * bi, y = ar * bi + ai * br, mag = p == 0 ? 1 : powf(x * x + y * y, p) + 1e-20
            re[k] = x / mag; im[k] = y / mag
        }
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_INVERSE))
            out.withUnsafeMutableBytes { vDSP_ztoc(&sc, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half)) } } }
        return (0...min(maxLag, n - 1)).map { abs(out[$0]) }
    }
    /// Strongest lag and how far it stands above the median (the "× noise" figure SpeakerSync uses; ≥ 6–8 = a clear detection).
    public static func peak(_ c: [Float]) -> (lag: Int, ratio: Float) {
        guard let m = c.indices.max(by: { c[$0] < c[$1] }) else { return (0, 0) }
        let med = c.sorted()[c.count / 2]
        return (m, c[m] / max(med, 1e-12))
    }
}
