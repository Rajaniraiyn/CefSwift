import Foundation

/// Writes decoded PCM as FLAC in fragmented MP4, the form a native
/// `audio/mp4; codecs="flac"` `SourceBuffer` takes: an initialization
/// segment per format, and a media segment per run of blocks.
///
/// The FLAC is verbatim (each subframe stores its samples as they are),
/// so the PCM reaches Chromium unchanged and writing it is a copy. The
/// decoder hands over planar, big-endian samples, which are a verbatim
/// subframe's bytes.
struct FlacFragmentWriter {
    /// What a stream's FLAC carries.
    struct Format: Equatable {
        var sampleRate: Int
        var channels: Int
        /// 16 or 24.
        var bitsPerSample: Int
        /// The largest block, in frames.
        var maximumBlockSize: Int

        var bytesPerSample: Int { bitsPerSample / 8 }
    }

    let format: Format
    /// `mfhd` sequence numbers, which a SourceBuffer expects to grow.
    private(set) var sequence: UInt32 = 0

    init(format: Format) {
        self.format = format
    }

    /// The `ftyp` and `moov` of a single FLAC track.
    func initializationSegment() -> Data {
        let rate = format.sampleRate, channels = format.channels, bits = format.bitsPerSample
        var info = [UInt8](repeating: 0, count: 34)
        // Minimum and maximum block size, then frame sizes left unknown.
        let maximum = min(max(format.maximumBlockSize, 16), 65535)
        info[0] = 0; info[1] = 16
        info[2] = UInt8(maximum >> 8); info[3] = UInt8(maximum & 255)
        // 20-bit rate, 3-bit channels - 1, 5-bit bits - 1, 36-bit total (0: unknown).
        info[10] = UInt8((rate >> 12) & 255)
        info[11] = UInt8((rate >> 4) & 255)
        info[12] = UInt8(((rate & 15) << 4) | ((channels - 1) << 1) | (((bits - 1) >> 4) & 1))
        info[13] = UInt8(((bits - 1) & 15) << 4)
        let dfLa = Box.full("dfLa", 0, 0, [0x80, 0, 0, 34] + info)
        let entry = Box.box("fLaC", [0, 0, 0, 0, 0, 0] + Box.u16(1) + [UInt8](repeating: 0, count: 8)
            + Box.u16(channels) + Box.u16(bits) + [0, 0, 0, 0] + Box.u32(rate > 65535 ? 0 : rate << 16) + dfLa)
        let stbl = Box.box("stbl", Box.full("stsd", 0, 0, Box.u32(1) + entry) + Box.full("stts", 0, 0, Box.u32(0))
            + Box.full("stsc", 0, 0, Box.u32(0)) + Box.full("stsz", 0, 0, Box.u32(0) + Box.u32(0))
            + Box.full("stco", 0, 0, Box.u32(0)))
        let dinf = Box.box("dinf", Box.full("dref", 0, 0, Box.u32(1) + Box.full("url ", 0, 1, [])))
        let minf = Box.box("minf", Box.full("smhd", 0, 0, [0, 0, 0, 0]) + dinf + stbl)
        let mdhd = Box.full("mdhd", 0, 0, Box.u32(0) + Box.u32(0) + Box.u32(rate) + Box.u32(0) + [0x55, 0xc4, 0, 0])
        let hdlr = Box.full("hdlr", 0, 0, Box.u32(0) + Box.fourcc("soun") + Box.u32(0) + Box.u32(0) + Box.u32(0)
            + Box.fourcc("SoundHandler") + [0])
        let mdia = Box.box("mdia", mdhd + hdlr + minf)
        let tkhd = Box.full("tkhd", 0, 3, Box.u32(0) + Box.u32(0) + Box.u32(1) + Box.u32(0) + Box.u32(0) + Box.u32(0)
            + Box.u32(0) + Box.u16(0) + Box.u16(0) + Box.u16(0x100) + Box.u16(0) + Box.matrix + Box.u32(0) + Box.u32(0))
        let mvhd = Box.full("mvhd", 0, 0, Box.u32(0) + Box.u32(0) + Box.u32(1000) + Box.u32(0) + Box.u32(0x10000)
            + Box.u16(0x100) + [UInt8](repeating: 0, count: 10) + Box.matrix + [UInt8](repeating: 0, count: 24) + Box.u32(2))
        let mvex = Box.box("mvex", Box.full("trex", 0, 0, Box.u32(1) + Box.u32(1) + Box.u32(0) + Box.u32(0) + Box.u32(0)))
        let ftyp = Box.box("ftyp", Box.fourcc("iso6") + Box.u32(0) + Box.fourcc("iso6") + Box.fourcc("mp41"))
        return Data(ftyp + Box.box("moov", mvhd + Box.box("trak", tkhd + mdia) + mvex))
    }

    /// A media segment of one MP4 sample per block. `planes` holds each
    /// channel's samples, big-endian, from the run's first frame; `blocks`
    /// are the blocks' lengths in frames; `startSample` is the first
    /// frame's time in samples at the stream's rate.
    mutating func mediaSegment(planes: [UnsafeRawBufferPointer], blocks: [Int], startSample: Int) -> Data {
        let channels = format.channels, bytes = format.bytesPerSample
        var frames: [(count: Int, size: Int)] = []
        var mdatBody = 0
        var number = startSample
        for count in blocks where count > 0 {
            let size = Self.frameHeader(channels: channels, bits: format.bitsPerSample, count: count, sampleNumber: max(0, number)).count
                + 1 + channels * (1 + bytes * count) + 2
            frames.append((count, size))
            mdatBody += size
            number += count
        }
        sequence &+= 1
        var trun: [UInt8] = []
        trun.reserveCapacity(frames.count * 8)
        for frame in frames { trun += Box.u32(frame.count) + Box.u32(frame.size) }
        func moof(dataOffset: Int) -> [UInt8] {
            Box.box("moof", Box.full("mfhd", 0, 0, Box.u32(Int(sequence)))
                + Box.box("traf", Box.full("tfhd", 0, 0x020000, Box.u32(1))
                    + Box.full("tfdt", 1, 0, Box.u64(max(0, startSample)))
                    + Box.full("trun", 0, 0x000301, Box.u32(frames.count) + Box.u32(dataOffset) + trun)))
        }
        let header = moof(dataOffset: 0).count
        var data = Data(capacity: header + 8 + mdatBody)
        data.append(contentsOf: moof(dataOffset: header + 8))
        data.append(contentsOf: Box.u32(mdatBody + 8) + Box.fourcc("mdat"))
        var first = 0
        number = startSample
        for count in blocks where count > 0 {
            let head = Self.frameHeader(channels: channels, bits: format.bitsPerSample, count: count, sampleNumber: max(0, number))
            let start = data.count
            data.append(contentsOf: head)
            data.append(Self.crc8(head))
            for plane in planes {
                // A verbatim subframe without wasted bits, then the samples.
                data.append(0x02)
                data.append(contentsOf: UnsafeRawBufferPointer(rebasing: plane[(first * bytes)..<((first + count) * bytes)]))
            }
            let crc = data.withUnsafeBytes { Self.crc16(UnsafeRawBufferPointer(rebasing: $0[start...])) }
            data.append(UInt8(crc >> 8))
            data.append(UInt8(crc & 255))
            first += count
            number += count
        }
        return data
    }

    /// A frame's header before its CRC-8: sync, variable block size coded
    /// at the end, rate and size from STREAMINFO's, channels, the first
    /// sample's number, and the block size - 1.
    static func frameHeader(channels: Int, bits: Int, count: Int, sampleNumber: Int) -> [UInt8] {
        // Sample size codes: 4 is 16 bits, 6 is 24.
        let sizeCode: UInt8 = bits == 24 ? 6 : 4
        return [0xff, 0xf9, 0x70, UInt8((channels - 1) << 4) | (sizeCode << 1)] + codedNumber(sampleNumber)
            + [UInt8(((count - 1) >> 8) & 255), UInt8((count - 1) & 255)]
    }

    /// FLAC's UTF-8-like coding of a frame's first sample number (36 bits).
    static func codedNumber(_ value: Int) -> [UInt8] {
        var n = value
        let bits = n == 0 ? 0 : Int.bitWidth - n.leadingZeroBitCount
        if bits <= 7 { return [UInt8(n)] }
        let continuation = bits <= 11 ? 1 : bits <= 16 ? 2 : bits <= 21 ? 3 : bits <= 26 ? 4 : bits <= 31 ? 5 : 6
        var tail: [UInt8] = []
        for _ in 0..<continuation {
            tail.insert(0x80 | UInt8(n & 63), at: 0)
            n >>= 6
        }
        let lead = UInt8((0xff << (7 - continuation)) & 0xff)
        return [lead | UInt8(n)] + tail
    }

    private static let crc8Table: [UInt8] = (0..<256).map { value in
        var c = UInt8(value)
        for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0x07 : c << 1 }
        return c
    }

    private static let crc16Table: [UInt16] = (0..<256).map { value in
        var c = UInt16(value) << 8
        for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x8005 : c << 1 }
        return c
    }

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var c: UInt8 = 0
        for byte in bytes { c = crc8Table[Int(c ^ byte)] }
        return c
    }

    static func crc16(_ bytes: UnsafeRawBufferPointer) -> UInt16 {
        var c: UInt16 = 0
        for byte in bytes { c = (c << 8) ^ crc16Table[Int(UInt8(c >> 8) ^ byte)] }
        return c
    }
}

/// ISO BMFF boxes as byte arrays.
enum Box {
    static func u16(_ n: Int) -> [UInt8] { [UInt8((n >> 8) & 255), UInt8(n & 255)] }
    static func u32(_ n: Int) -> [UInt8] {
        [UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]
    }
    static func u64(_ n: Int) -> [UInt8] { u32(Int(UInt64(n) >> 32)) + u32(n & 0xffff_ffff) }
    static func fourcc(_ s: String) -> [UInt8] { Array(s.utf8) }
    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] { u32(body.count + 8) + fourcc(type) + body }
    static func full(_ type: String, _ version: UInt8, _ flags: Int, _ body: [UInt8]) -> [UInt8] {
        box(type, [version, UInt8((flags >> 16) & 255), UInt8((flags >> 8) & 255), UInt8(flags & 255)] + body)
    }
    static let matrix: [UInt8] = u32(0x10000) + u32(0) + u32(0) + u32(0) + u32(0x10000) + u32(0) + u32(0) + u32(0)
        + u32(0x4000_0000)
}
