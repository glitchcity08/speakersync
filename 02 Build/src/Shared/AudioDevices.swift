// Shared Core Audio helpers for SpeakerSync and its tools (SyncProbe).
// Namespaced under `SSAudio` so it can be compiled next to SpeakerSync's own main.swift without clashes;
// when SpeakerSync adopts it, its file-level helpers (ids, str, nominalRate, …) can be deleted.
import Foundation
import CoreAudio

public struct SSDevice: Equatable { public let id: AudioObjectID; public let name: String; public let uid: String }

public enum SSAudio {
    public static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func address(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               _ el: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        .init(mSelector: s, mScope: sc, mElement: el)
    }
    public static func objects(_ o: AudioObjectID, _ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(s, sc); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(o, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var r = [AudioObjectID](repeating: 0, count: Int(size) / 4); AudioObjectGetPropertyData(o, &a, 0, nil, &size, &r); return r
    }
    public static func string(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
        var a = address(s); var v: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v) == noErr else { return "" }
        return (v?.takeRetainedValue() as String?) ?? ""
    }
    public static func uint32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var a = address(s, sc); var v: UInt32 = 0; var size: UInt32 = 4; AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v); return v
    }
    public static func sampleRate(_ o: AudioObjectID) -> Double {
        var a = address(kAudioDevicePropertyNominalSampleRate); var v: Float64 = 0; var size: UInt32 = 8
        AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v); return v
    }
    public static func setSampleRate(_ o: AudioObjectID, _ r: Double) {
        var a = address(kAudioDevicePropertyNominalSampleRate); var v = r; AudioObjectSetPropertyData(o, &a, 0, nil, 8, &v)
    }
    public static func hasOutput(_ d: AudioObjectID) -> Bool { !objects(d, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).isEmpty }
    public static func hasInput(_ d: AudioObjectID) -> Bool { !objects(d, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).isEmpty }
    public static func devices() -> [SSDevice] {
        objects(system, kAudioHardwarePropertyDevices).map { SSDevice(id: $0, name: string($0, kAudioObjectPropertyName), uid: string($0, kAudioDevicePropertyDeviceUID)) }
    }
    public static func device(uid: String) -> SSDevice? { devices().first { $0.uid == uid } }
    /// Interleaved/non-interleaved Float32 output writer used by every IOProc.
    public static func write(_ l: UnsafeMutableAudioBufferListPointer, frames n: Int, _ f: (Int) -> (Float, Float)) {
        if l.count == 1, let d = l[0].mData?.assumingMemoryBound(to: Float.self) {
            let ch = Int(l[0].mNumberChannels)
            for i in 0..<n { let (L, R) = f(i); d[i * ch] = L; if ch > 1 { d[i * ch + 1] = R; if ch > 2 { for c in 2..<ch { d[i * ch + c] = 0 } } } }
        } else if l.count >= 2, let dl = l[0].mData?.assumingMemoryBound(to: Float.self), let dr = l[1].mData?.assumingMemoryBound(to: Float.self) {
            for i in 0..<n { let (L, R) = f(i); dl[i] = L; dr[i] = R }
        }
    }
    public static func frames(_ l: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let b = l.first, b.mNumberChannels > 0 else { return 0 }; return Int(b.mDataByteSize) / 4 / Int(b.mNumberChannels)
    }
    public static let hostTicksToSeconds: Double = { var tb = mach_timebase_info_data_t(); _ = mach_timebase_info(&tb); return Double(tb.numer) / Double(tb.denom) * 1e-9 }()
}
