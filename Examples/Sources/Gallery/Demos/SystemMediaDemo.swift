import AVFoundation
import CefSwiftUI
import SwiftUI

/// `services.systemMediaDecoders = .audio` (the gallery turns it on, and
/// its `cefapp.json` lists the `systemMediaDecoders` capability) plays
/// AAC, HE-AAC, Apple Lossless, AC-3 and E-AC-3 in Chromium pages with the
/// decoders macOS ships, in CefSwift's sandboxed media service. The demo
/// makes a few seconds of music in each codec AVFoundation can encode and
/// plays them in plain `<audio>` elements, and through Media Source
/// Extensions, beside what `MediaSource.isTypeSupported` answers.
struct SystemMediaDemo: Demo {
    let title = "System Media Decoders"
    let summary = "AAC, HE-AAC and Apple Lossless in <audio> and MediaSource, decoded by macOS in a sandboxed service; the page's element and clock stay Chromium's."
    let symbol = "waveform"
    let category = DemoCategory.page

    func makeView() -> some View { SystemMediaDemoView() }
}

private struct SystemMediaDemoView: View {
    @State private var page: CefPage?

    var body: some View {
        Group {
            if let page {
                CefWebView(page)
            } else {
                ProgressView("Encoding the samples…")
            }
        }
        .task {
            await SystemMediaSamples.prepare()
            page = CefPage(url: SystemMediaSamples.page.url)
        }
        .reportReady {
            while page == nil { try await Task.sleep(for: .milliseconds(50)) }
            try await page?.waitUntilLoaded(timeout: .seconds(30))
        }
        .onDisappear { page?.close(force: true) }
    }
}

@MainActor
private enum SystemMediaSamples {
    static let page = SamplePage("system-media/index.html", title: "System media decoders", body: """
        <h1>System media decoders</h1>
        <p class=muted>Each file below is made by AVFoundation when the demo opens. Chromium's own build plays none of
        them; the media shim hands each to macOS's decoder in CefSwift's media service and plays the result,
        losslessly, through the page's own MediaSource.</p>
        <div class=card id=support></div>
        <div class=card>
          <p><b>AAC-LC</b> (<code>mp4a.40.2</code>) <audio controls src=aac.m4a></audio></p>
          <p><b>HE-AAC</b> (<code>mp4a.40.5</code>) <audio controls src=he.m4a></audio></p>
          <p><b>HE-AAC v2</b> (<code>mp4a.40.29</code>) <audio controls src=hev2.m4a></audio></p>
          <p><b>Apple Lossless, 24-bit</b> (<code>alac</code>) <audio controls src=alac.m4a></audio></p>
          <p><b>Media Source Extensions</b>, AAC appended in one-second fragments <audio controls id=mse></audio></p>
        </div>
        <script>
          const types = ['mp4a.40.2', 'mp4a.40.5', 'mp4a.40.29', 'mp4a.40.42', 'alac', 'ac-3', 'ec-3']
            .map((c) => `audio/mp4; codecs="${c}"`).concat(['video/mp4; codecs="avc1.640028"']);
          document.getElementById('support').innerHTML = '<b>MediaSource.isTypeSupported</b><br>' +
            types.map((t) => `<code>${t}</code>: ${MediaSource.isTypeSupported(t) ? 'yes' : 'no'}`).join('<br>');
          (async () => {
            const a = document.getElementById('mse'), ms = new MediaSource();
            a.src = URL.createObjectURL(ms);
            await new Promise((r) => ms.addEventListener('sourceopen', r, { once: true }));
            const sb = ms.addSourceBuffer('audio/mp4; codecs="mp4a.40.2"');
            const count = +(await (await fetch('segment-count')).text());
            for (const name of ['segment-init.mp4', ...Array.from({ length: count }, (_, i) => `segment-${i}.m4s`)]) {
              const bytes = await (await fetch(name)).arrayBuffer();
              await new Promise((r) => { sb.addEventListener('updateend', r, { once: true }); sb.appendBuffer(bytes); });
            }
            ms.endOfStream();
          })();
        </script>
        """)

    private static var isPrepared = false

    /// A few seconds of an arpeggio in each codec, as files and as
    /// fragmented MP4, served beside the page.
    static func prepare() async {
        guard !isPrepared else { return }
        isPrepared = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-system-media-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files: [(String, AudioFormatID, Int)] = [
            ("aac.m4a", kAudioFormatMPEG4AAC, 16), ("he.m4a", kAudioFormatMPEG4AAC_HE, 16),
            ("hev2.m4a", kAudioFormatMPEG4AAC_HE_V2, 16), ("alac.m4a", kAudioFormatAppleLossless, 24),
        ]
        for (name, format, bits) in files {
            let url = directory.appendingPathComponent(name)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a),
                  (try? await write(with: writer, format: format, bits: bits)) != nil,
                  let data = try? Data(contentsOf: url)
            else { continue }
            serve("system-media/\(name)", mimeType: "audio/mp4", data)
        }
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero
        let segments = Segments()
        writer.delegate = segments
        if (try? await write(with: writer, format: kAudioFormatMPEG4AAC, bits: 16)) != nil {
            serve("system-media/segment-init.mp4", mimeType: "video/mp4", segments.initialization)
            for (index, data) in segments.media.enumerated() {
                serve("system-media/segment-\(index).m4s", mimeType: "video/mp4", data)
            }
            serve("system-media/segment-count", mimeType: "text/plain", Data(String(segments.media.count).utf8))
        }
    }

    private static func serve(_ path: String, mimeType: String, _ data: Data) {
        SamplePages.store.withLock { $0[path] = (mimeType, data) }
    }

    private final class Segments: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        var initialization = Data()
        var media: [Data] = []
        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType,
                         segmentReport: AVAssetSegmentReport?) {
            if segmentType == .initialization { initialization = data } else { media.append(data) }
        }
    }

    /// Six seconds of an A minor arpeggio, in stereo at 48 kHz.
    private static func write(with writer: AVAssetWriter, format: AudioFormatID, bits: Int) async throws {
        let rate = 48000.0
        var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
        if format == kAudioFormatAppleLossless { settings[AVEncoderBitDepthHintKey] = bits }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription)
        guard let formatDescription else { throw CocoaError(.fileWriteUnknown) }
        let notes = [220.0, 261.63, 329.63, 440, 329.63, 261.63]
        let total = Int(rate * 6)
        var sample = 0
        while sample < total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let count = min(1024, total - sample)
            var pcm = [Float](repeating: 0, count: count * 2)
            for i in 0..<count {
                let t = Double(sample + i) / rate
                let beat = t * 4
                let note = notes[Int(beat) % notes.count]
                let envelope = exp(-3 * beat.truncatingRemainder(dividingBy: 1))
                let value = Float(sin(2 * .pi * note * t) * envelope * 0.35)
                pcm[2 * i] = value
                pcm[2 * i + 1] = value * 0.8
            }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: count * 8, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: count * 8, flags: 0, blockBufferOut: &block)
            guard let block else { throw CocoaError(.fileWriteUnknown) }
            pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 8) }
            var buffer: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: formatDescription, sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(sample), timescale: CMTimeScale(rate)),
                packetDescriptions: nil, sampleBufferOut: &buffer)
            guard let buffer, input.append(buffer) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            sample += count
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
