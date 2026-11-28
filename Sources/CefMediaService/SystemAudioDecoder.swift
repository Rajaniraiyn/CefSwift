import AudioToolbox
import Foundation

/// Decodes one audio stream with AudioToolbox into planar, big-endian
/// integer PCM in FLAC's channel order, the bytes of FLAC's verbatim
/// subframes.
///
/// One decoder decodes one stream: AAC frames overlap, so packets decoded
/// in a row join without a seam, and a stream that jumps (a seek) starts
/// over with ``reset()``.
final class SystemAudioDecoder {
    /// The codecs, by the MP4 sample entry's four-character code.
    enum Codec: String, CaseIterable {
        /// AAC-LC, HE-AAC, HE-AAC v2 and xHE-AAC; the configuration is the
        /// `esds` box's ES descriptor.
        case aac = "mp4a"
        /// Apple Lossless; the configuration is the `alac` box.
        case appleLossless = "alac"
        /// Dolby Digital; the configuration is the `dac3` box's body.
        case ac3 = "ac-3"
        /// Dolby Digital Plus; the configuration is the `dec3` box's body.
        case enhancedAC3 = "ec-3"
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    let output: FlacFragmentWriter.Format
    private let converter: AudioConverterRef
    /// For each FLAC channel, the decoder's channel that goes there.
    private let order: [Int]

    init(codec: Codec, sampleRate: Double, channels: Int, configuration: [UInt8]) throws {
        var input = try Self.inputFormat(codec: codec, sampleRate: sampleRate, channels: channels, configuration: configuration)
        guard input.mSampleRate > 0, input.mSampleRate <= 384_000, (1...8).contains(input.mChannelsPerFrame) else {
            throw Failure("unsupported format: \(input.mSampleRate) Hz, \(input.mChannelsPerFrame) channels")
        }
        // Lossless sources keep their depth; everything else is 16-bit.
        let bits = codec == .appleLossless && input.mFormatFlags != kAppleLosslessFormatFlag_16BitSourceData ? 24 : 16
        let channelCount = Int(input.mChannelsPerFrame)
        var outputDescription = AudioStreamBasicDescription(
            mSampleRate: input.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(bits / 8), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bits / 8),
            mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: UInt32(bits), mReserved: 0)
        var converter: AudioConverterRef?
        let status = AudioConverterNew(&input, &outputDescription, &converter)
        guard status == noErr, let converter else { throw Failure("AudioConverterNew: \(Self.code(status))") }
        if !configuration.isEmpty, codec == .aac || codec == .appleLossless {
            let cookieStatus = configuration.withUnsafeBytes {
                AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
            }
            guard cookieStatus == noErr else {
                AudioConverterDispose(converter)
                throw Failure("the decoder refused the configuration: \(Self.code(cookieStatus))")
            }
        }
        self.converter = converter
        order = AudioChannelOrder.flacOrder(
            of: Self.outputLayout(of: converter, codec: codec, configuration: configuration, channels: channelCount),
            channels: channelCount)
        output = FlacFragmentWriter.Format(
            sampleRate: Int(input.mSampleRate), channels: channelCount, bitsPerSample: bits,
            maximumBlockSize: max(Int(input.mFramesPerPacket), 1024))
    }

    deinit { AudioConverterDispose(converter) }

    /// Forgets the previous packets, for a stream that does not continue
    /// from them.
    func reset() { AudioConverterReset(converter) }

    /// The most frames a packet can decode to.
    var maximumFramesPerPacket: Int { output.maximumBlockSize * 2 }

    /// Decoded audio: one buffer per FLAC channel, each holding the
    /// frames of every packet back to back, and how many frames each
    /// packet produced.
    final class Planes {
        let buffers: [UnsafeMutableRawBufferPointer]
        let bytesPerSample: Int
        var frames: [Int] = []

        init(channels: Int, capacity: Int, bytesPerSample: Int) {
            self.bytesPerSample = bytesPerSample
            buffers = (0..<channels).map { _ in
                UnsafeMutableRawBufferPointer.allocate(byteCount: max(capacity * bytesPerSample, 1), alignment: 16)
            }
        }

        deinit { buffers.forEach { $0.deallocate() } }

        var frameCount: Int { frames.reduce(0, +) }

        /// Each channel's samples from frame `first` to `first + count`.
        func planes(from first: Int, count: Int) -> [UnsafeRawBufferPointer] {
            buffers.map { UnsafeRawBufferPointer(rebasing: $0[(first * bytesPerSample)..<((first + count) * bytesPerSample)]) }
        }

        /// Replaces `count` frames from `first` with silence.
        func silence(from first: Int, count: Int) {
            for buffer in buffers {
                UnsafeMutableRawBufferPointer(rebasing: buffer[(first * bytesPerSample)..<((first + count) * bytesPerSample)])
                    .initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
    }

    /// Decodes the packets laid out back to back in `packets`, each
    /// straight into its place in the planes, in FLAC's channel order. A
    /// packet the decoder rejects produces no frames.
    func decode(packets: UnsafeRawBufferPointer, sizes: [Int]) -> Planes {
        let channels = output.channels, bytes = output.bytesPerSample
        let capacity = maximumFramesPerPacket
        let planes = Planes(channels: channels, capacity: capacity * sizes.count, bytesPerSample: bytes)
        planes.frames.reserveCapacity(sizes.count)
        let feed = Feed(packets: packets, sizes: sizes)
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(list.unsafeMutablePointer) }
        var filled = 0
        for _ in sizes {
            feed.allowance = 1
            // The decoder's channel `order[slot]` is FLAC's channel `slot`.
            for slot in 0..<channels {
                list[order[slot]] = AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(capacity * bytes),
                    mData: planes.buffers[slot].baseAddress! + filled * bytes)
            }
            var produced = UInt32(capacity)
            let status = withExtendedLifetime(feed) {
                AudioConverterFillComplexBuffer(
                    converter, Self.supply, Unmanaged.passUnretained(feed).toOpaque(), &produced,
                    list.unsafeMutablePointer, nil)
            }
            if status != noErr && status != Feed.exhausted { produced = 0 }
            filled += Int(produced)
            planes.frames.append(Int(produced))
        }
        return planes
    }

    // MARK: Formats

    /// The compressed format the decoder takes, from the sample entry.
    static func inputFormat(codec: Codec, sampleRate: Double, channels: Int, configuration: [UInt8]) throws
        -> AudioStreamBasicDescription
    {
        switch codec {
        case .aac, .appleLossless:
            // The decoder's own reading of the configuration, the highest
            // layer first: HE-AAC reports its SBR rate there.
            let formatID = codec == .aac ? kAudioFormatMPEG4AAC : kAudioFormatAppleLossless
            guard let first = formatList(formatID: formatID, cookie: configuration).first else {
                throw Failure("the decoder does not read this configuration")
            }
            return first
        case .ac3, .enhancedAC3:
            let parsed = codec == .ac3 ? DolbyConfiguration(dac3: configuration) : DolbyConfiguration(dec3: configuration)
            return AudioStreamBasicDescription(
                mSampleRate: parsed?.sampleRate ?? sampleRate,
                mFormatID: codec == .ac3 ? kAudioFormatAC3 : kAudioFormatEnhancedAC3, mFormatFlags: 0,
                mBytesPerPacket: 0, mFramesPerPacket: 1536, mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(parsed?.channels ?? channels), mBitsPerChannel: 0, mReserved: 0)
        }
    }

    private static func formatList(formatID: AudioFormatID, cookie: [UInt8]) -> [AudioStreamBasicDescription] {
        cookie.withUnsafeBytes { raw -> [AudioStreamBasicDescription] in
            guard let address = raw.baseAddress else { return [] }
            var info = AudioFormatInfo(
                mASBD: AudioStreamBasicDescription(
                    mSampleRate: 0, mFormatID: formatID, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
                    mBytesPerFrame: 0, mChannelsPerFrame: 0, mBitsPerChannel: 0, mReserved: 0),
                mMagicCookie: address, mMagicCookieSize: UInt32(raw.count))
            let infoSize = UInt32(MemoryLayout<AudioFormatInfo>.size)
            var size: UInt32 = 0
            guard AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList, infoSize, &info, &size) == noErr,
                  size >= UInt32(MemoryLayout<AudioFormatListItem>.size)
            else { return [] }
            var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: Int(size) / MemoryLayout<AudioFormatListItem>.size)
            guard AudioFormatGetProperty(kAudioFormatProperty_FormatList, infoSize, &info, &size, &items) == noErr else { return [] }
            return items.map(\.mASBD)
        }
    }

    /// The decoder's output channel labels, in its order: what the
    /// converter reports, else what the stream's configuration says.
    private static func outputLayout(of converter: AudioConverterRef, codec: Codec, configuration: [UInt8], channels: Int)
        -> [AudioChannelLabel]
    {
        for property in [kAudioConverterOutputChannelLayout, kAudioConverterInputChannelLayout] {
            var size: UInt32 = 0
            guard AudioConverterGetPropertyInfo(converter, property, &size, nil) == noErr,
                  size >= UInt32(MemoryLayout<AudioChannelLayout>.size)
            else { continue }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { raw.deallocate() }
            guard AudioConverterGetProperty(converter, property, &size, raw) == noErr else { continue }
            let labels = AudioChannelOrder.labels(of: raw.assumingMemoryBound(to: AudioChannelLayout.self))
            if labels.count == channels { return labels }
        }
        guard codec == .aac, !configuration.isEmpty else { return [] }
        return configuration.withUnsafeBytes { cookie -> [AudioChannelLabel] in
            var size: UInt32 = 0
            guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutFromESDS, UInt32(cookie.count), cookie.baseAddress, &size) == noErr,
                  size >= UInt32(MemoryLayout<AudioChannelLayout>.size)
            else { return [] }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { raw.deallocate() }
            guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutFromESDS, UInt32(cookie.count), cookie.baseAddress, &size, raw) == noErr
            else { return [] }
            return AudioChannelOrder.labels(of: raw.assumingMemoryBound(to: AudioChannelLayout.self))
        }
    }

    static func code(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
        if bytes.allSatisfy({ (0x20...0x7e).contains($0) }) { return "'\(String(decoding: bytes, as: UTF8.self))'" }
        return String(status)
    }

    // MARK: Feeding packets

    /// Hands the converter one packet per call to `decode`'s loop.
    private final class Feed {
        static let exhausted: OSStatus = 0x6d6f_7265  // 'more': no packet for now
        let packets: UnsafeRawBufferPointer
        let sizes: [Int]
        var index = 0
        var offset = 0
        var allowance = 0
        var description = AudioStreamPacketDescription()

        init(packets: UnsafeRawBufferPointer, sizes: [Int]) {
            self.packets = packets
            self.sizes = sizes
        }
    }

    private static let supply: AudioConverterComplexInputDataProc = { _, count, data, descriptions, user in
        guard let user else { return Feed.exhausted }
        let feed = Unmanaged<Feed>.fromOpaque(user).takeUnretainedValue()
        guard feed.allowance > 0, feed.index < feed.sizes.count else {
            count.pointee = 0
            return Feed.exhausted
        }
        let size = feed.sizes[feed.index]
        guard size > 0, feed.offset + size <= feed.packets.count, let base = feed.packets.baseAddress else {
            count.pointee = 0
            return Feed.exhausted
        }
        // The packets stay mapped, unchanged, for the whole call.
        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: base + feed.offset)
        data.pointee.mBuffers.mDataByteSize = UInt32(size)
        feed.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
        if let descriptions {
            descriptions.pointee = withUnsafeMutablePointer(to: &feed.description) { $0 }
        }
        feed.offset += size
        feed.index += 1
        feed.allowance -= 1
        count.pointee = 1
        return noErr
    }
}

/// The sample rate and channel count in an MP4's `dac3` or `dec3` box
/// (ETSI TS 102 366, annex F).
struct DolbyConfiguration: Equatable {
    var sampleRate: Double
    var channels: Int

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    private static let rates: [Double] = [48000, 44100, 32000]
    /// Full-bandwidth channels by `acmod`.
    private static let modeChannels = [2, 1, 2, 3, 3, 4, 4, 5]

    init?(dac3 body: [UInt8]) {
        guard body.count >= 3 else { return nil }
        var bits = BitReader(body)
        let fscod = bits.read(2)
        bits.skip(5 + 3)  // bsid, bsmod
        let acmod = bits.read(3)
        let lfe = bits.read(1)
        guard fscod < 3 else { return nil }
        sampleRate = Self.rates[fscod]
        channels = Self.modeChannels[acmod] + lfe
    }

    init?(dec3 body: [UInt8]) {
        guard body.count >= 5 else { return nil }
        var bits = BitReader(body)
        bits.skip(13)  // data_rate
        guard bits.read(3) >= 0 else { return nil }  // num_ind_sub - 1; the first substream decides
        let fscod = bits.read(2)
        bits.skip(5 + 1 + 1 + 3)  // bsid, reserved, asvc, bsmod
        let acmod = bits.read(3)
        let lfe = bits.read(1)
        bits.skip(3)
        let dependent = bits.read(4)
        var extra = 0
        if dependent > 0 {
            // chan_loc: Lc/Rc, Lrs/Rrs, Cs, Ts, Lsd/Rsd, Lw/Rw, Lvh/Rvh, Cvh, LFE2.
            let pairs = [2, 2, 1, 1, 2, 2, 2, 1, 1]
            let location = bits.read(9)
            for (bit, count) in pairs.enumerated() where location & (1 << (8 - bit)) != 0 { extra += count }
        }
        guard fscod < 3, !bits.isPastEnd else { return nil }
        sampleRate = Self.rates[fscod]
        channels = Self.modeChannels[acmod] + lfe + extra
    }
}

/// Reads big-endian bit fields.
struct BitReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isPastEnd: Bool { position > bytes.count * 8 }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byte = position / 8 < bytes.count ? Int(bytes[position / 8]) : 0
            value = (value << 1) | ((byte >> (7 - position % 8)) & 1)
            position += 1
        }
        return value
    }

    mutating func skip(_ count: Int) { position += count }
}
