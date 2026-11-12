import AVFoundation
import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// The experimental system-decoder media shim
/// (`CefMediaCompatibility.systemDecoders`). The option is app-wide, so
/// this process checks that pages see nothing of it while it is off, and a
/// second SelfTest process with it on plays AAC made here with
/// AVFoundation and served from `selftest://app/media/`.
extension SelfTest {
    static let mediaShimProbeEnvironmentKey = "CEFSWIFT_SELFTEST_MEDIA_SHIM_ROOT"

    /// The AAC files the probe serves, by path. Set before any page loads.
    nonisolated(unsafe) static var mediaFiles: [String: Data] = [:]

    static func mediaShimChecks() async {
        let browser = CefBrowser(url: URL(string: "selftest://app/media.html")!)
        let view = CefWindowedBrowserView()
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        view.browser = browser
        defer {
            browser.close(force: true)
            view.removeFromSuperview()
        }
        guard await waitUntil(timeout: .seconds(15), { browser.state == .live && !browser.isLoading }) else {
            check("media shim: page loads", false)
            return
        }
        await expect("media shim off: AAC is not supported, as in CEF") {
            try await browser.evaluateJavaScript("""
                !MediaSource.isTypeSupported('audio/mp4; codecs="mp4a.40.2"')
                  && document.createElement('audio').canPlayType('audio/mp4; codecs="mp4a.40.2"') === ''
                """).boolValue == true
        }
        await expect("media shim off: the page's media functions are Chromium's") {
            try await browser.evaluateJavaScript("""
                [MediaSource.isTypeSupported, MediaSource.prototype.addSourceBuffer, HTMLMediaElement.prototype.canPlayType,
                 Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src').get]
                  .every(f => /\\{ \\[native code\\] \\}$/.test(Function.prototype.toString.call(f)))
                """).boolValue == true
        }
        await mediaShimProbe()
    }

    /// Runs this app again with the shim on and reports what it found.
    static func mediaShimProbe() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-selftest-media-\(ProcessInfo.processInfo.processIdentifier)")
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var environment = ProcessInfo.processInfo.environment
        environment[mediaShimProbeEnvironmentKey] = root.path
        environment["SELFTEST_ONLY"] = nil
        probe.environment = environment
        let output = Pipe()
        probe.standardOutput = output
        do {
            try probe.run()
        } catch {
            check("media shim: probe starts", false, detail: "\(error)")
            return
        }
        let finished = await waitUntil(timeout: .seconds(60)) { !probe.isRunning }
        if !finished { probe.terminate() }
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        for line in lines where line.hasPrefix("NOTE ") || line.hasPrefix("PASS ") || line.hasPrefix("FAIL ") || line.hasPrefix("SKIP ") {
            if line.hasPrefix("FAIL ") { failures += 1 }
            print(line.replacingOccurrences(of: "quit:", with: "media shim: probe quit:"))
        }
        check("media shim: probe finishes", finished && probe.terminationStatus == 0,
              detail: finished ? "status \(probe.terminationStatus)" : "still running")
        try? FileManager.default.removeItem(at: root)
    }

    /// The probe process, with `CefMediaCompatibility.systemDecoders`.
    static func mediaShimProbeChecks() async {
        do {
            mediaFiles = try await makeAACMedia()
        } catch {
            check("media shim: AVFoundation writes the test media", false, detail: "\(error)")
            return
        }
        let browser = CefBrowser(url: URL(string: "selftest://app/media.html")!)
        let view = CefWindowedBrowserView()
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        view.browser = browser
        defer {
            browser.close(force: true)
            view.removeFromSuperview()
        }
        guard await waitUntil(timeout: .seconds(15), { browser.state == .live && !browser.isLoading }) else {
            check("media shim: page loads", false)
            return
        }
        await expect("media shim: AAC is supported, through MediaSource and media elements") {
            try await browser.evaluateJavaScript("""
                MediaSource.isTypeSupported('audio/mp4; codecs="mp4a.40.2"')
                  && document.createElement('audio').canPlayType('audio/mp4; codecs="mp4a.40.2"') === 'probably'
                  && !MediaSource.isTypeSupported('video/mp4; codecs="avc1.640028"')
                """).boolValue == true
        }
        await expect("media shim: no globals of its own") {
            try await browser.evaluateJavaScript("""
                Object.getOwnPropertyNames(window).filter(n => /shim|cefswift|native|flac|mp4/i.test(n)).length === 0
                """).boolValue == true
        }
        let mse = try? await browser.evaluateJavaScript("playMSE()")
        check("media shim: MediaSource AAC buffers without a gap",
              mse?["ranges"].intValue == 1 && (mse?["end"].doubleValue ?? 0) > 3.9,
              detail: mse?.text ?? "no result")
        check("media shim: MediaSource AAC plays and is not silent",
              (mse?["advanced"].doubleValue ?? 0) > 0.5 && (mse?["rms"].doubleValue ?? 0) > 0.05,
              detail: mse?.text ?? "no result")
        let file = try? await browser.evaluateJavaScript("playFile()")
        check("media shim: an .m4a in <audio> plays and is not silent",
              file?["error"].isNull == true && (file?["advanced"].doubleValue ?? 0) > 0.5 && (file?["rms"].doubleValue ?? 0) > 0.05,
              detail: file?.text ?? "no result")
        check("media shim: seeking in an .m4a lands where asked",
              abs((file?["seekedAt"].doubleValue ?? 0) - 3) < 0.1, detail: file?.text ?? "no result")
        check("media shim: <audio>.src stays the page's address",
              file?["src"].stringValue == "selftest://app/media/tone.m4a", detail: file?.text ?? "no result")
    }

    /// A 5-second 440 Hz tone in AAC-LC: a progressive `.m4a` and an fMP4
    /// initialization segment with media segments.
    static func makeAACMedia() async throws -> [String: Data] {
        var files: [String: Data] = [:]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-selftest-aac-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let progressive = directory.appendingPathComponent("tone.m4a")
        let writer = try AVAssetWriter(outputURL: progressive, fileType: .m4a)
        try await writeTone(with: writer)
        files["/media/tone.m4a"] = try Data(contentsOf: progressive)

        let segmented = AVAssetWriter(contentType: .mpeg4Movie)
        segmented.outputFileTypeProfile = .mpeg4AppleHLS
        segmented.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        segmented.initialSegmentStartTime = .zero
        let segments = SegmentCollector()
        segmented.delegate = segments
        try await writeTone(with: segmented)
        files["/media/init.mp4"] = segments.initialization
        for (index, data) in segments.media.enumerated() { files["/media/seg\(index).m4s"] = data }
        files["/media/count"] = Data(String(segments.media.count).utf8)
        return files
    }

    private final class SegmentCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        var initialization = Data()
        var media: [Data] = []
        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType,
                         segmentReport: AVAssetSegmentReport?) {
            if segmentType == .initialization { initialization = data } else { media.append(data) }
        }
    }

    private static func writeTone(with writer: AVAssetWriter) async throws {
        let rate = 48000.0
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard let format else { throw CocoaError(.fileWriteUnknown) }
        let total = Int(rate * 5)
        var sample = 0
        while sample < total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let count = min(1024, total - sample)
            var pcm = [Int16](repeating: 0, count: count * 2)
            for i in 0..<count {
                let value = Int16(sin(2 * .pi * 440 * Double(sample + i) / rate) * 0.3 * 32767)
                pcm[2 * i] = value
                pcm[2 * i + 1] = value
            }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 4, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: count * 4, flags: 0,
                                               blockBufferOut: &block)
            guard let block else { throw CocoaError(.fileWriteUnknown) }
            pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 4) }
            var buffer: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(sample), timescale: CMTimeScale(rate)),
                packetDescriptions: nil, sampleBufferOut: &buffer)
            guard let buffer, input.append(buffer) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            sample += count
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// The page for both processes: `playMSE()` and `playFile()` resolve to
    /// what they measured.
    nonisolated static let mediaShimPage = """
        <title>media</title>
        <script>
          const wait = (ms) => new Promise(r => setTimeout(r, ms));
          async function listen(a, seconds) {
            const ctx = new AudioContext(); const an = ctx.createAnalyser();
            ctx.createMediaElementSource(a).connect(an); an.connect(ctx.destination);
            await ctx.resume(); const start = a.currentTime; await a.play();
            const buf = new Float32Array(2048); let peak = 0;
            for (let i = 0; i < seconds * 10; i++) {
              await wait(100); an.getFloatTimeDomainData(buf);
              let e = 0; for (const v of buf) e += v * v; peak = Math.max(peak, Math.sqrt(e / buf.length));
            }
            return { advanced: a.currentTime - start, rms: peak, ctx };
          }
          async function playMSE() {
            const a = document.createElement('audio'); document.body.append(a);
            const ms = new MediaSource(); a.src = URL.createObjectURL(ms);
            await new Promise(r => ms.addEventListener('sourceopen', r, { once: true }));
            const sb = ms.addSourceBuffer('audio/mp4; codecs="mp4a.40.2"');
            const get = async (p) => new Uint8Array(await (await fetch('/media/' + p)).arrayBuffer());
            const append = (b) => new Promise((res, rej) => {
              sb.addEventListener('updateend', res, { once: true });
              sb.addEventListener('error', () => rej(new Error('append failed')), { once: true });
              sb.appendBuffer(b);
            });
            const count = +(await (await fetch('/media/count')).text());
            await append(await get('init.mp4'));
            for (let i = 0; i < count; i++) await append(await get(`seg${i}.m4s`));
            ms.endOfStream();
            const heard = await listen(a, 1.5);
            heard.ctx.close(); a.pause();
            return { ranges: sb.buffered.length, end: sb.buffered.end(0), advanced: heard.advanced, rms: heard.rms };
          }
          async function playFile() {
            const a = document.createElement('audio'); document.body.append(a);
            a.src = '/media/tone.m4a';
            await Promise.race([new Promise(r => a.addEventListener('canplay', r, { once: true })), wait(8000)]);
            if (a.error) return { error: a.error.code };
            const heard = await listen(a, 1.5);
            a.currentTime = 3;
            await new Promise(r => a.addEventListener('seeked', r, { once: true }));
            const seekedAt = a.currentTime;
            heard.ctx.close(); a.pause();
            return { error: null, advanced: heard.advanced, rms: heard.rms, seekedAt, src: a.src };
          }
        </script>
        """
}
