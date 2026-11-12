import AudioToolbox

/// Decodes AAC (LC, HE, HE v2) to 16-bit interleaved PCM with the system's
/// AudioToolbox decoder, for ``CefMediaCompatibility/systemDecoders``.
///
/// One decoder decodes one stream: AAC frames overlap, so packets decoded
/// in a row join without a seam, and a stream that jumps (a seek) starts
/// over with ``reset()``.
final class CefSystemAudioDecoder {
    let sampleRate: Double
    let channels: Int
    private let converter: AudioConverterRef
    private let maximumFramesPerPacket: Int

    /// `cookie` is the `esds` box's ES descriptor (the box body after its
    /// version and flags), as an MP4 file carries it.
    init?(cookie: [UInt8]) {
        // The decoder's own reading of the cookie, the highest layer first:
        // HE-AAC reports its SBR rate there, not the core rate.
        var listSize: UInt32 = 0
        var input = AudioStreamBasicDescription()
        let found = cookie.withUnsafeBytes { raw -> Bool in
            guard let cookieAddress = raw.baseAddress else { return false }
            var info = AudioFormatInfo(
                mASBD: AudioStreamBasicDescription(
                    mSampleRate: 0, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                    mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 0, mBitsPerChannel: 0, mReserved: 0),
                mMagicCookie: cookieAddress, mMagicCookieSize: UInt32(raw.count))
            let infoSize = UInt32(MemoryLayout<AudioFormatInfo>.size)
            guard AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList, infoSize, &info, &listSize) == noErr,
                  listSize >= UInt32(MemoryLayout<AudioFormatListItem>.size)
            else { return false }
            var items = [AudioFormatListItem](
                repeating: AudioFormatListItem(), count: Int(listSize) / MemoryLayout<AudioFormatListItem>.size)
            guard AudioFormatGetProperty(kAudioFormatProperty_FormatList, infoSize, &info, &listSize, &items) == noErr,
                  let first = items.first
            else { return false }
            input = first.mASBD
            return true
        }
        guard found, input.mSampleRate > 0, input.mChannelsPerFrame > 0 else { return nil }
        var output = AudioStreamBasicDescription(
            mSampleRate: input.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * input.mChannelsPerFrame, mFramesPerPacket: 1,
            mBytesPerFrame: 2 * input.mChannelsPerFrame, mChannelsPerFrame: input.mChannelsPerFrame,
            mBitsPerChannel: 16, mReserved: 0)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return nil }
        let cookieSet = cookie.withUnsafeBytes {
            AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
        }
        guard cookieSet == noErr else {
            AudioConverterDispose(converter)
            return nil
        }
        self.converter = converter
        sampleRate = input.mSampleRate
        channels = Int(input.mChannelsPerFrame)
        maximumFramesPerPacket = max(Int(input.mFramesPerPacket), 1024) * 2
    }

    deinit { AudioConverterDispose(converter) }

    /// Forgets the previous packets, for a stream that does not continue
    /// from them.
    func reset() { AudioConverterReset(converter) }

    /// Decodes `sizes.count` packets laid out back to back in `packets`.
    /// Returns the PCM and how many frames each packet produced.
    func decode(packets: [UInt8], sizes: [Int]) -> (pcm: [Int16], frames: [Int]) {
        let feed = Feed(data: packets, sizes: sizes)
        var pcm: [Int16] = []
        var frames: [Int] = []
        pcm.reserveCapacity(sizes.count * 1024 * channels)
        var buffer = [Int16](repeating: 0, count: maximumFramesPerPacket * channels)
        let unmanaged = Unmanaged.passUnretained(feed)
        for _ in sizes {
            feed.allowance = 1
            var produced = UInt32(maximumFramesPerPacket)
            let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, Self.supply, unmanaged.toOpaque(), &produced, &list, nil)
            }
            if status != noErr && status != Feed.exhausted { produced = 0 }
            frames.append(Int(produced))
            pcm.append(contentsOf: buffer.prefix(Int(produced) * channels))
        }
        return (pcm, frames)
    }

    /// Hands the converter one packet per call to `decode`'s loop.
    private final class Feed {
        static let exhausted: OSStatus = 0x6d6f7265  // 'more': no packet for now
        var data: [UInt8]
        let sizes: [Int]
        var index = 0
        var offset = 0
        var allowance = 0
        var description = AudioStreamPacketDescription()

        init(data: [UInt8], sizes: [Int]) {
            self.data = data
            self.sizes = sizes
        }
    }

    private static let supply: AudioConverterComplexInputDataProc = { _, packets, data, descriptions, user in
        guard let user else { return Feed.exhausted }
        let feed = Unmanaged<Feed>.fromOpaque(user).takeUnretainedValue()
        guard feed.allowance > 0, feed.index < feed.sizes.count else {
            packets.pointee = 0
            return Feed.exhausted
        }
        let size = feed.sizes[feed.index]
        guard size > 0, feed.offset + size <= feed.data.count else {
            packets.pointee = 0
            return Feed.exhausted
        }
        // The feed outlives the converter call, and its storage does not
        // move while the call reads it.
        feed.data.withUnsafeMutableBytes { raw in
            data.pointee.mBuffers.mData = raw.baseAddress.map { $0 + feed.offset }
        }
        data.pointee.mBuffers.mDataByteSize = UInt32(size)
        feed.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
        if let descriptions {
            descriptions.pointee = withUnsafeMutablePointer(to: &feed.description) { $0 }
        }
        feed.offset += size
        feed.index += 1
        feed.allowance -= 1
        packets.pointee = 1
        return noErr
    }
}
