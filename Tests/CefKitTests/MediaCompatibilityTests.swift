import AudioToolbox
import Foundation
import Testing

@testable import CefKit

@Suite struct MediaCompatibilityTests {
    @Test func offByDefaultInEveryPreset() {
        #expect(CefConfiguration().mediaCompatibility == .none)
        #expect(CefConfiguration.embedded.mediaCompatibility == .none)
        #expect(CefConfiguration.browser.mediaCompatibility == .none)
    }

    /// AAC-LC made with the system's encoder: packets, and the ES
    /// descriptor an MP4 `esds` box would carry.
    private static func encodeTone(seconds: Double) throws -> (packets: [UInt8], sizes: [Int], cookie: [UInt8]) {
        let rate = 48000.0
        var input = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var output = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var converter: AudioConverterRef?
        try #require(AudioConverterNew(&input, &output, &converter) == noErr)
        let encoder = try #require(converter)
        defer { AudioConverterDispose(encoder) }
        var cookieSize: UInt32 = 0
        AudioConverterGetPropertyInfo(encoder, kAudioConverterCompressionMagicCookie, &cookieSize, nil)
        var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
        AudioConverterGetProperty(encoder, kAudioConverterCompressionMagicCookie, &cookieSize, &cookie)

        final class Source { var pcm: [Int16]; var offset = 0; init(_ pcm: [Int16]) { self.pcm = pcm } }
        let frames = Int(rate * seconds)
        let source = Source((0..<frames * 2).map { Int16(sin(2 * .pi * 440 * Double($0 / 2) / rate) * 0.3 * 32767) })
        var packets: [UInt8] = [], sizes: [Int] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        var descriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: 1)
        while true {
            var count: UInt32 = 1
            let status = buffer.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(encoder, { _, packets, data, _, user in
                    let source = Unmanaged<Source>.fromOpaque(user!).takeUnretainedValue()
                    let available = (source.pcm.count - source.offset) / 2
                    guard available > 0 else { packets.pointee = 0; return noErr }
                    let take = min(Int(packets.pointee), available, 1024)
                    source.pcm.withUnsafeMutableBytes { data.pointee.mBuffers.mData = $0.baseAddress! + source.offset * 2 }
                    data.pointee.mBuffers.mDataByteSize = UInt32(take * 4)
                    data.pointee.mBuffers.mNumberChannels = 2
                    source.offset += take * 2
                    packets.pointee = UInt32(take)
                    return noErr
                }, Unmanaged.passUnretained(source).toOpaque(), &count, &list, &descriptions)
            }
            guard status == noErr, count > 0 else { break }
            let size = Int(descriptions[0].mDataByteSize)
            packets += buffer.prefix(size)
            sizes.append(size)
        }
        return (packets, sizes, cookie)
    }

    @Test func systemDecoderTurnsEachAACPacketIntoOneBlock() throws {
        let tone = try Self.encodeTone(seconds: 1)
        try #require(tone.sizes.count > 40)
        let decoder = try #require(CefSystemAudioDecoder(cookie: tone.cookie))
        #expect(decoder.sampleRate == 48000)
        #expect(decoder.channels == 2)
        // Two calls, as two MediaSource appends: the second continues the first.
        let half = tone.sizes.count / 2
        let split = tone.sizes.prefix(half).reduce(0, +)
        let first = decoder.decode(packets: Array(tone.packets.prefix(split)), sizes: Array(tone.sizes.prefix(half)))
        let second = decoder.decode(packets: Array(tone.packets.dropFirst(split)), sizes: Array(tone.sizes.dropFirst(half)))
        #expect((first.frames + second.frames).allSatisfy { $0 == 1024 })
        #expect(first.pcm.count + second.pcm.count == tone.sizes.count * 1024 * 2)
        // Past the encoder's priming the tone is there, at its level.
        let peak = second.pcm.map { abs(Int($0)) }.max() ?? 0
        #expect(abs(peak - Int(0.3 * 32767)) < 1500)
    }

    @Test func systemDecoderRejectsWhatIsNotAAC() {
        #expect(CefSystemAudioDecoder(cookie: []) == nil)
        #expect(CefSystemAudioDecoder(cookie: [1, 2, 3, 4, 5]) == nil)
    }
}
