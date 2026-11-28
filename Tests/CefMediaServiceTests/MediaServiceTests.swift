import AudioToolbox
import Foundation
import Testing

@testable import CefMediaService

@Suite struct MediaServiceTests {
    /// Compressed audio made with the system's encoder: packets, their
    /// sizes, and the configuration an MP4 sample entry would carry.
    struct Encoded {
        var packets: [UInt8]
        var sizes: [Int]
        var configuration: [UInt8]
        var framesPerPacket: Int
    }

    /// `frequencies[c]` Hz in channel `c`, at 48 kHz, in the layout `tag`.
    static func encode(
        format: AudioFormatID, frequencies: [Double], seconds: Double, layout tag: AudioChannelLayoutTag? = nil,
        flags: AudioFormatFlags = 0
    ) throws -> Encoded {
        let rate = 48000.0
        let channels = UInt32(frequencies.count)
        var input = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1, mBytesPerFrame: 2 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        var output = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: format, mFormatFlags: flags, mBytesPerPacket: 0,
            mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        var converter: AudioConverterRef?
        try #require(AudioConverterNew(&input, &output, &converter) == noErr)
        let encoder = try #require(converter)
        defer { AudioConverterDispose(encoder) }
        if let tag {
            var layout = AudioChannelLayout(mChannelLayoutTag: tag, mChannelBitmap: [], mNumberChannelDescriptions: 0,
                                            mChannelDescriptions: AudioChannelDescription())
            let size = UInt32(MemoryLayout<AudioChannelLayout>.size)
            try #require(AudioConverterSetProperty(encoder, kAudioConverterInputChannelLayout, size, &layout) == noErr)
        }
        var described = AudioStreamBasicDescription()
        var describedSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioConverterGetProperty(encoder, kAudioConverterCurrentOutputStreamDescription, &describedSize, &described)
        var cookieSize: UInt32 = 0
        AudioConverterGetPropertyInfo(encoder, kAudioConverterCompressionMagicCookie, &cookieSize, nil)
        var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
        AudioConverterGetProperty(encoder, kAudioConverterCompressionMagicCookie, &cookieSize, &cookie)

        final class Source {
            var pcm: [Int16]
            var offset = 0
            let channels: Int
            init(_ pcm: [Int16], channels: Int) { self.pcm = pcm; self.channels = channels }
        }
        let frames = Int(rate * seconds)
        var pcm = [Int16](repeating: 0, count: frames * Int(channels))
        for i in 0..<frames {
            for (c, frequency) in frequencies.enumerated() {
                pcm[i * Int(channels) + c] = Int16(sin(2 * .pi * frequency * Double(i) / rate) * 0.3 * 32767)
            }
        }
        let source = Source(pcm, channels: Int(channels))
        var packets: [UInt8] = [], sizes: [Int] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var descriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: 1)
        while true {
            var count: UInt32 = 1
            let status = buffer.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(encoder, { _, packets, data, _, user in
                    let source = Unmanaged<Source>.fromOpaque(user!).takeUnretainedValue()
                    let available = (source.pcm.count - source.offset) / source.channels
                    guard available > 0 else { packets.pointee = 0; return noErr }
                    let take = min(Int(packets.pointee), available, 4096)
                    source.pcm.withUnsafeMutableBytes { data.pointee.mBuffers.mData = $0.baseAddress! + source.offset * 2 }
                    data.pointee.mBuffers.mDataByteSize = UInt32(take * 2 * source.channels)
                    data.pointee.mBuffers.mNumberChannels = UInt32(source.channels)
                    source.offset += take * source.channels
                    packets.pointee = UInt32(take)
                    return noErr
                }, Unmanaged.passUnretained(source).toOpaque(), &count, &list, &descriptions)
            }
            guard status == noErr, count > 0 else { break }
            let size = Int(descriptions[0].mDataByteSize)
            packets += buffer.prefix(size)
            sizes.append(size)
        }
        return Encoded(packets: packets, sizes: sizes, configuration: cookie, framesPerPacket: Int(described.mFramesPerPacket))
    }

    /// Big-endian 16-bit samples of one FLAC plane.
    static func samples(_ plane: UnsafeRawBufferPointer) -> [Int16] {
        stride(from: 0, to: plane.count - 1, by: 2).map { Int16(bitPattern: UInt16(plane[$0]) << 8 | UInt16(plane[$0 + 1])) }
    }

    /// Upward zero crossings per second: about the tone's frequency.
    static func frequency(_ samples: ArraySlice<Int16>, rate: Double = 48000) -> Double {
        var crossings = 0
        var previous = samples.first ?? 0
        for sample in samples.dropFirst() {
            if previous < 0, sample >= 0 { crossings += 1 }
            previous = sample
        }
        return Double(crossings) * rate / Double(samples.count)
    }

    @Test func decodesAACPacketsIntoOneBlockEach() throws {
        let tone = try Self.encode(format: kAudioFormatMPEG4AAC, frequencies: [440, 440], seconds: 1)
        try #require(tone.sizes.count > 40)
        let decoder = try SystemAudioDecoder(codec: .aac, sampleRate: 48000, channels: 2, configuration: tone.configuration)
        #expect(decoder.output == .init(sampleRate: 48000, channels: 2, bitsPerSample: 16, maximumBlockSize: 1024))
        // Two calls, as two MediaSource appends: the second continues the first.
        let half = tone.sizes.count / 2
        let split = tone.sizes.prefix(half).reduce(0, +)
        let first = tone.packets.withUnsafeBytes { decoder.decode(packets: UnsafeRawBufferPointer(rebasing: $0[..<split]), sizes: Array(tone.sizes.prefix(half))) }
        let second = tone.packets.withUnsafeBytes { decoder.decode(packets: UnsafeRawBufferPointer(rebasing: $0[split...]), sizes: Array(tone.sizes.dropFirst(half))) }
        #expect((first.frames + second.frames).allSatisfy { $0 == 1024 })
        // Past the encoder's priming the tone is there, at its level.
        let left = Self.samples(second.planes(from: 0, count: second.frameCount)[0])
        let peak = left.map { abs(Int($0)) }.max() ?? 0
        #expect(abs(peak - Int(0.3 * 32767)) < 1500)
        #expect(abs(Self.frequency(left[...]) - 440) < 5)
    }

    @Test func decodesHEAACAtItsOutputRate() throws {
        let tone = try Self.encode(format: kAudioFormatMPEG4AAC_HE, frequencies: [440, 440], seconds: 1)
        let decoder = try SystemAudioDecoder(codec: .aac, sampleRate: 48000, channels: 2, configuration: tone.configuration)
        #expect(decoder.output.sampleRate == 48000)
        let planes = tone.packets.withUnsafeBytes { decoder.decode(packets: $0, sizes: tone.sizes) }
        #expect(planes.frames.dropFirst(2).allSatisfy { $0 == 2048 })
    }

    @Test func keepsAppleLosslessExactAndItsDepth() throws {
        let tone = try Self.encode(
            format: kAudioFormatAppleLossless, frequencies: [440, 660], seconds: 0.5, flags: kAppleLosslessFormatFlag_16BitSourceData)
        let decoder = try SystemAudioDecoder(codec: .appleLossless, sampleRate: 48000, channels: 2, configuration: tone.configuration)
        #expect(decoder.output.bitsPerSample == 16)
        #expect(decoder.output.maximumBlockSize == 4096)
        let planes = tone.packets.withUnsafeBytes { decoder.decode(packets: $0, sizes: tone.sizes) }
        let right = Self.samples(planes.planes(from: 0, count: planes.frameCount)[1])
        // Lossless: sample for sample the input.
        let expected = (0..<right.count).map { Int16(sin(2 * .pi * 660 * Double($0) / 48000) * 0.3 * 32767) }
        #expect(right == expected)
    }

    @Test func putsSurroundChannelsInFLACOrder() throws {
        // WAVE 5.1 input: L R C LFE Ls Rs. AAC stores it as C L R Ls Rs LFE.
        let frequencies: [Double] = [500, 750, 1000, 62.5, 1250, 1500]
        let tone = try Self.encode(
            format: kAudioFormatMPEG4AAC, frequencies: frequencies, seconds: 1, layout: kAudioChannelLayoutTag_WAVE_5_1_A)
        let decoder = try SystemAudioDecoder(codec: .aac, sampleRate: 48000, channels: 6, configuration: tone.configuration)
        #expect(decoder.output.channels == 6)
        let planes = tone.packets.withUnsafeBytes { decoder.decode(packets: $0, sizes: tone.sizes) }
        let measured = planes.planes(from: 0, count: planes.frameCount).map { Self.frequency(Self.samples($0).dropFirst(4096)) }
        for (index, frequency) in frequencies.enumerated() {
            #expect(abs(measured[index] - frequency) < frequency * 0.05, "channel \(index): \(measured)")
        }
    }

    @Test func mapsLabelsToFLACSlots() {
        let aac51: [AudioChannelLabel] = [
            kAudioChannelLabel_Center, kAudioChannelLabel_Left, kAudioChannelLabel_Right,
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_LFEScreen,
        ]
        #expect(AudioChannelOrder.flacOrder(of: aac51, channels: 6) == [1, 2, 0, 5, 3, 4])
        let wave71: [AudioChannelLabel] = [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
            kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
        ]
        #expect(AudioChannelOrder.flacOrder(of: wave71, channels: 8) == Array(0..<8))
        // Labels FLAC has no place for keep the decoder's order.
        let wide: [AudioChannelLabel] = [
            kAudioChannelLabel_Center, kAudioChannelLabel_LeftCenter, kAudioChannelLabel_RightCenter,
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LeftSurround,
            kAudioChannelLabel_RightSurround, kAudioChannelLabel_LFEScreen,
        ]
        #expect(AudioChannelOrder.flacOrder(of: wide, channels: 8) == Array(0..<8))
        #expect(AudioChannelOrder.flacOrder(of: [kAudioChannelLabel_Left, kAudioChannelLabel_Right], channels: 2) == [0, 1])
    }

    @Test func readsDolbyConfigurations() {
        // dac3: fscod 0 (48 kHz), bsid 8, bsmod 0, acmod 7 (3/2), lfeon 1.
        #expect(DolbyConfiguration(dac3: [0x10, 0x3d, 0xe0]) == DolbyConfiguration(sampleRate: 48000, channels: 6) as DolbyConfiguration?)
        // dec3: 7.1 as 5.1 plus a dependent substream with Lrs/Rrs.
        let dec3: [UInt8] = [0x06, 0x00, 0x20, 0x0f, 0x02, 0x80]
        #expect(DolbyConfiguration(dec3: dec3)?.channels == 8)
        #expect(DolbyConfiguration(dac3: [0xc0, 0, 0]) == nil)
    }

    @Test func refusesWhatItCannotDecode() {
        #expect(throws: SystemAudioDecoder.Failure.self) {
            try SystemAudioDecoder(codec: .aac, sampleRate: 48000, channels: 2, configuration: [])
        }
        #expect(throws: SystemAudioDecoder.Failure.self) {
            try SystemAudioDecoder(codec: .aac, sampleRate: 48000, channels: 2, configuration: [1, 2, 3, 4, 5])
        }
        #expect(throws: SystemAudioDecoder.Failure.self) {
            try MediaService.Request(packets: Data(count: 4), sizes: Data(count: 4), timing: Data(count: 8))
        }
    }

    @Test func writesFLACFramesTheSystemDecoderReadsBack() throws {
        let tone = try Self.encode(format: kAudioFormatMPEG4AAC, frequencies: [440, 440], seconds: 1)
        let decoder = try SystemAudioDecoder(codec: .aac, sampleRate: 48000, channels: 2, configuration: tone.configuration)
        let stream = AudioStream(decoder: decoder)
        let timing = tone.sizes.indices.map { AudioStream.Timing(start: Double($0 * 1024) / 48000, duration: 1024.0 / 48000) }
        let segments = tone.packets.withUnsafeBytes {
            stream.append(packets: $0, sizes: tone.sizes, timing: timing, discontinuity: false)
        }
        try #require(segments.count == 2)
        let initialization = [UInt8](segments[0]), media = [UInt8](segments[1])
        #expect(initialization.count > 100)
        #expect(String(decoding: initialization[4..<8], as: UTF8.self) == "ftyp")
        #expect(String(decoding: media[4..<8], as: UTF8.self) == "moof")
        // Every FLAC frame's CRC-16 holds: find the frames through the trun.
        let frames = try Self.flacFrames(in: media)
        #expect(frames.count == tone.sizes.count)
        for frame in frames {
            let crc = frame.withUnsafeBytes { FlacFragmentWriter.crc16(UnsafeRawBufferPointer(rebasing: $0[..<(frame.count - 2)])) }
            #expect(UInt16(frame[frame.count - 2]) << 8 | UInt16(frame[frame.count - 1]) == crc)
            #expect(frame[0] == 0xff && frame[1] == 0xf9)
        }
        // The next request continues the timeline: one media segment, no
        // new initialization.
        let more = tone.packets.withUnsafeBytes {
            stream.append(packets: UnsafeRawBufferPointer(rebasing: $0[..<tone.sizes[0]]), sizes: [tone.sizes[0]],
                          timing: [AudioStream.Timing(start: 1024.0 * Double(tone.sizes.count) / 48000, duration: 1024.0 / 48000)],
                          discontinuity: false)
        }
        #expect(more.count == 1)
    }

    @Test func skipsPrimingBeforeTimeZero() {
        var run = AudioStream.Run(start: -2112, first: 0, blocks: [1024, 1024, 1024, 1024])
        run.skipPriming()
        #expect(run.start == 0)
        #expect(run.first == 2112)
        #expect(run.blocks == [960, 1024])
    }

    @Test func codesSampleNumbersAsFLACDoes() {
        #expect(FlacFragmentWriter.codedNumber(0) == [0])
        #expect(FlacFragmentWriter.codedNumber(127) == [127])
        #expect(FlacFragmentWriter.codedNumber(128) == [0xc2, 0x80])
        #expect(FlacFragmentWriter.codedNumber(48000) == [0xeb, 0xae, 0x80])
    }

    /// The FLAC frames of a media segment, by its trun's sample sizes.
    static func flacFrames(in segment: [UInt8]) throws -> [[UInt8]] {
        func u32(_ o: Int) -> Int { Int(segment[o]) << 24 | Int(segment[o + 1]) << 16 | Int(segment[o + 2]) << 8 | Int(segment[o + 3]) }
        let trun = try #require((0..<(segment.count - 4)).first { segment[$0..<($0 + 4)].elementsEqual("trun".utf8) })
        let count = u32(trun + 8)
        var offset = u32(trun + 12)
        var frames: [[UInt8]] = []
        for index in 0..<count {
            let size = u32(trun + 16 + index * 8 + 4)
            frames.append(Array(segment[offset..<(offset + size)]))
            offset += size
        }
        return frames
    }
}
