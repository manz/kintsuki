import Foundation
import CryptoKit

/// `.kcr` (Kintsuki Crash Recovery) file format. Captures the rewind
/// ring, crash-site CPU snapshot, and shadow-callstack backtrace at the
/// moment a ROM hit STP. Reload via `CrashDump.read(from:)` for
/// post-mortem stepping in the debugger or via the Python crash loader.
///
/// Layout (little-endian, packed):
///   magic         : 4   bytes — "KCR1"
///   version       : u32       — 1
///   romSHA256     : 32  bytes
///   adbgSHA256    : 32  bytes — all zero when no .adbg sidecar
///   romPathLen    : u32
///   romPath       : N   bytes — UTF-8, no NUL terminator
///   keyframeInt   : u32
///   capacity      : u32
///   crashPC       : u32
///   crashCpuBlob  : 32  bytes — packed CpuState (a/x/y/s/d u16 ×5,
///                              b/p u8 ×2, pc u32, e/stp/wai u8 ×3)
///                              tail-padded to 32 bytes for forward-compat.
///   backtraceLen  : u32
///   backtraceJSON : N   bytes
///   frameCount    : u32
///   frames…       : per-frame record:
///                     kind : u8  — 0 keyframe, 1 delta
///                     if keyframe: u32 length, N bytes
///                     if delta:    u32 kfIndex, u32 compLen, N bytes
struct CrashDump {
    static let magic: [UInt8] = [0x4B, 0x43, 0x52, 0x31]  // "KCR1"
    static let version: UInt32 = 1

    let romPath: String
    let romSHA256: Data
    let adbgSHA256: Data?         // nil → 32 zero bytes on disk
    let crashPC: UInt32
    let crashCpu: Emulator.CpuState
    let backtraceJSON: Data
    let keyframeInterval: Int
    let capacity: Int
    let frames: [RewindBuffer.SerializedFrame]

    /// SHA-256 of a file on disk. Returns 32 zero bytes on read failure
    /// — the dump still records what's known so dev tooling can salvage
    /// partial state without throwing.
    static func sha256(of url: URL) -> Data {
        guard let data = try? Data(contentsOf: url) else {
            return Data(repeating: 0, count: 32)
        }
        var h = SHA256()
        h.update(data: data)
        return Data(h.finalize())
    }

    func write(to url: URL) throws {
        var blob = Data()
        blob.reserveCapacity(64 * 1024 * 1024)
        blob.append(contentsOf: Self.magic)
        appendU32(&blob, Self.version)
        appendFixed(&blob, romSHA256, length: 32)
        appendFixed(&blob, adbgSHA256 ?? Data(repeating: 0, count: 32), length: 32)
        let pathBytes = Array(romPath.utf8)
        appendU32(&blob, UInt32(pathBytes.count))
        blob.append(contentsOf: pathBytes)
        appendU32(&blob, UInt32(keyframeInterval))
        appendU32(&blob, UInt32(capacity))
        appendU32(&blob, crashPC)
        appendCpuBlob(&blob, crashCpu)
        appendU32(&blob, UInt32(backtraceJSON.count))
        blob.append(backtraceJSON)
        appendU32(&blob, UInt32(frames.count))
        for f in frames {
            switch f {
            case .keyframe(let bytes):
                blob.append(0)
                appendU32(&blob, UInt32(bytes.count))
                blob.append(bytes)
            case .delta(let kfIndex, let compressed):
                blob.append(1)
                appendU32(&blob, UInt32(kfIndex))
                appendU32(&blob, UInt32(compressed.count))
                blob.append(compressed)
            }
        }
        try blob.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> CrashDump {
        let blob = try Data(contentsOf: url)
        var cur = 0
        func need(_ n: Int) throws {
            if cur + n > blob.count { throw DumpError.truncated }
        }
        func readU8() throws -> UInt8 { try need(1); defer { cur += 1 }; return blob[cur] }
        func readU32() throws -> UInt32 {
            try need(4)
            defer { cur += 4 }
            let bytes = blob[cur..<cur+4]
            return bytes.withUnsafeBytes { raw -> UInt32 in
                raw.load(as: UInt32.self).littleEndian
            }
        }
        func readData(_ n: Int) throws -> Data {
            try need(n)
            defer { cur += n }
            return Data(blob[cur..<cur+n])
        }

        try need(4)
        let m = Array(blob[cur..<cur+4]); cur += 4
        guard m == Self.magic else { throw DumpError.badMagic }
        let v = try readU32()
        guard v == Self.version else { throw DumpError.unsupportedVersion(v) }
        let romHash = try readData(32)
        let adbgHash = try readData(32)
        let romPathLen = Int(try readU32())
        let romPath = String(data: try readData(romPathLen), encoding: .utf8) ?? ""
        let kfi = Int(try readU32())
        let cap = Int(try readU32())
        let crashPC = try readU32()
        let cpu = try readCpuBlob(blob, &cur)
        let btLen = Int(try readU32())
        let bt = try readData(btLen)
        let frameCount = Int(try readU32())
        var frames: [RewindBuffer.SerializedFrame] = []
        frames.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            let kind = try readU8()
            if kind == 0 {
                let len = Int(try readU32())
                let bytes = try readData(len)
                frames.append(.keyframe(bytes: bytes))
            } else if kind == 1 {
                let kfIdx = Int(try readU32())
                let cl = Int(try readU32())
                let comp = try readData(cl)
                frames.append(.delta(kfIndex: kfIdx, compressed: comp))
            } else {
                throw DumpError.unknownFrameKind(kind)
            }
        }
        let adbgOpt: Data? = adbgHash.allSatisfy { $0 == 0 } ? nil : adbgHash
        return CrashDump(romPath: romPath, romSHA256: romHash,
                         adbgSHA256: adbgOpt,
                         crashPC: crashPC, crashCpu: cpu,
                         backtraceJSON: bt,
                         keyframeInterval: kfi, capacity: cap,
                         frames: frames)
    }

    enum DumpError: Error {
        case badMagic
        case truncated
        case unsupportedVersion(UInt32)
        case unknownFrameKind(UInt8)
    }
}

// MARK: - Helpers

private func appendU32(_ data: inout Data, _ v: UInt32) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}

private func appendU16(_ data: inout Data, _ v: UInt16) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}

private func appendFixed(_ data: inout Data, _ src: Data, length: Int) {
    if src.count >= length {
        data.append(src.prefix(length))
    } else {
        data.append(src)
        data.append(Data(repeating: 0, count: length - src.count))
    }
}

private func appendCpuBlob(_ data: inout Data, _ s: Emulator.CpuState) {
    var blob = Data(); blob.reserveCapacity(32)
    appendU16(&blob, s.a); appendU16(&blob, s.x); appendU16(&blob, s.y)
    appendU16(&blob, s.s); appendU16(&blob, s.d)
    blob.append(s.b); blob.append(s.p)
    var pc = s.pc.littleEndian
    withUnsafeBytes(of: &pc) { blob.append(contentsOf: $0) }
    blob.append(s.e ? 1 : 0)
    blob.append(s.stp ? 1 : 0)
    blob.append(s.wai ? 1 : 0)
    while blob.count < 32 { blob.append(0) }
    data.append(blob)
}

private func readCpuBlob(_ blob: Data, _ cur: inout Int) throws -> Emulator.CpuState {
    if cur + 32 > blob.count { throw CrashDump.DumpError.truncated }
    let r = blob[cur..<cur+32]
    cur += 32
    return r.withUnsafeBytes { raw -> Emulator.CpuState in
        let p = raw.bindMemory(to: UInt8.self).baseAddress!
        func u16(_ off: Int) -> UInt16 {
            UInt16(p[off]) | (UInt16(p[off+1]) << 8)
        }
        func u32(_ off: Int) -> UInt32 {
            UInt32(p[off]) | (UInt32(p[off+1]) << 8) |
            (UInt32(p[off+2]) << 16) | (UInt32(p[off+3]) << 24)
        }
        return Emulator.CpuState(
            a: u16(0), x: u16(2), y: u16(4),
            s: u16(6), d: u16(8),
            b: p[10], p: p[11],
            pc: u32(12),
            e: p[16] != 0, stp: p[17] != 0, wai: p[18] != 0
        )
    }
}
