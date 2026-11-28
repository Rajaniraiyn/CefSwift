import AVFoundation
import AppKit
@_spi(Testing) import CefKit

/// The system media decoders (`services.systemMediaDecoders`). The option
/// is app-wide, so this instance checks that pages see nothing of it while
/// it is off, and a probe with `.audio` plays audio made here with
/// AVFoundation, served from `selftest://media/`.
extension SelfTest {
    static func systemMediaChecks() async {
        let page = CefPage(url: URL(string: "selftest://media/index.html")!)
        let view = hostWindowed(page)
        defer {
            page.close(force: true)
            view.removeFromSuperview()
        }
        guard await loaded(page) else {
            check("system media: page loads", false)
            return
        }
        await expect("system media off: AAC is not supported, as in CEF") {
            try await page.evaluateJavaScript("""
                !MediaSource.isTypeSupported('audio/mp4; codecs="mp4a.40.2"')
                  && document.createElement('audio').canPlayType('audio/mp4; codecs="mp4a.40.2"') === ''
                """).boolValue == true
        }
        let natives = try? await page.evaluateJavaScript("inspectFunctions()")
        check("system media off: the page's media functions are Chromium's",
              natives?["appendBuffer"]["toString"].stringValue == "function appendBuffer() { [native code] }",
              detail: natives?.text ?? "no result")
        check("system media: the app carries the media service", CefRuntime.shared.capabilities.hasSystemMediaService)
        await runProbe("systemMedia", label: "system media", timeout: .seconds(90))
    }

    /// The probe, with `.audio`.
    static func systemMediaProbeChecks() async {
        do {
            SystemMediaPages.files = try await makeSystemMedia()
        } catch {
            check("AVFoundation writes the test media", false, detail: "\(error)")
            return
        }
        let page = CefPage(url: URL(string: "selftest://media/index.html")!)
        let view = hostWindowed(page)
        defer {
            page.close(force: true)
            view.removeFromSuperview()
        }
        guard await loaded(page) else {
            check("page loads", false)
            return
        }
        let support = try? await page.evaluateJavaScript("support()")
        check("AAC, HE-AAC, xHE-AAC, ALAC, AC-3 and E-AC-3 are supported through MediaSource and canPlayType",
              ["aac", "he", "xhe", "alac", "ac3", "ec3"].allSatisfy { support?[$0].boolValue == true }
                  && support?["canPlay"].stringValue == "probably" && support?["canPlayBare"].stringValue == "maybe",
              detail: support?.text ?? "no result")
        check("H.264, and types mixing it with AAC, stay unsupported",
              support?["h264"].boolValue == false && support?["mixed"].boolValue == false, detail: support?.text ?? "")

        let natives = try? await page.evaluateJavaScript("inspectFunctions()")
        let names = ["isTypeSupported", "addSourceBuffer", "endOfStream", "appendBuffer", "remove", "abort", "changeType",
                     "canPlayType", "decodingInfo", "Audio"]
        check("the replaced functions print as native code under their names",
              names.allSatisfy { natives?[$0]["toString"].stringValue == "function \($0)() { [native code] }" }
                  && natives?["updating"]["toString"].stringValue == "function get updating() { [native code] }"
                  && natives?["src"]["toString"].stringValue == "function get src() { [native code] }",
              detail: natives?.text ?? "no result")
        check("the replaced functions keep their lengths",
              natives?["isTypeSupported"]["length"].intValue == 1 && natives?["appendBuffer"]["length"].intValue == 1
                  && natives?["remove"]["length"].intValue == 2 && natives?["abort"]["length"].intValue == 0,
              detail: natives?.text ?? "")
        check("no globals of its own", natives?["globals"].arrayValue?.isEmpty == true, detail: natives?.text ?? "")
        check("a replaced function rethrows Chromium's own exceptions",
              natives?["illegal"].stringValue?.hasPrefix("TypeError: Illegal invocation") == true
                  && natives?["closedAdd"].stringValue?.hasPrefix("InvalidStateError") == true,
              detail: natives?.text ?? "")

        let mse = try? await page.evaluateJavaScript("playMSE('aac')")
        check("MediaSource AAC buffers without a gap",
              mse?["ranges"].intValue == 1 && (mse?["end"].doubleValue ?? 0) > 3.9, detail: mse?.text ?? "no result")
        check("MediaSource AAC plays a 440 Hz tone",
              (mse?["advanced"].doubleValue ?? 0) > 0.5 && (mse?["rms"].doubleValue ?? 0) > 0.05
                  && abs((mse?["frequencies"][0].doubleValue ?? 0) - 440) < 15,
              detail: mse?.text ?? "no result")
        check("addSourceBuffer returns a genuine SourceBuffer, which sourceBuffers lists",
              mse?["sameObject"].boolValue == true && mse?["proto"].boolValue == true, detail: mse?.text ?? "")
        check("each append fires one updatestart, update and updateend",
              mse?["events"].stringValue == Array(repeating: "updatestart,update,updateend", count: 7).joined(separator: ","),
              detail: mse?.text ?? "")
        let he = try? await page.evaluateJavaScript(#"playMSE('he', 'audio/mp4; codecs="mp4a.40.5"')"#)
        check("MediaSource HE-AAC plays", (he?["advanced"].doubleValue ?? 0) > 0.5 && (he?["rms"].doubleValue ?? 0) > 0.05,
              detail: he?.text ?? "no result")

        for (name, label) in [("aac.m4a", "AAC-LC"), ("he.m4a", "HE-AAC"), ("hev2.m4a", "HE-AAC v2"), ("alac.m4a", "ALAC"),
                              ("alac24.m4a", "24-bit ALAC"), ("aac.aac", "ADTS AAC")] {
            let file = try? await page.evaluateJavaScript("playFile('\(name)')")
            check("\(label) in <audio> plays and is not silent",
                  file?["error"].isNull == true && (file?["advanced"].doubleValue ?? 0) > 0.5
                      && (file?["rms"].doubleValue ?? 0) > 0.05,
                  detail: file?.text ?? "no result")
            if name == "aac.m4a" {
                check("seeking in an .m4a lands where asked",
                      abs((file?["seekedAt"].doubleValue ?? 0) - 3) < 0.1, detail: file?.text ?? "")
                check("<audio>.src and currentSrc stay the page's address",
                      file?["src"].stringValue == "selftest://media/media/aac.m4a"
                          && file?["currentSrc"].stringValue == "selftest://media/media/aac.m4a",
                      detail: file?.text ?? "")
            }
        }
        // FLAC's order: L R C LFE Ls Rs. AAC stores 5.1 as C L R Ls Rs LFE.
        let surround = try? await page.evaluateJavaScript("playFile('aac51.m4a', 6)")
        let expected = [500.0, 750, 1000, 62.5, 1250, 1500]
        let measured = (0..<6).map { surround?["frequencies"][$0].doubleValue ?? 0 }
        check("5.1 AAC plays each channel in its place",
              zip(measured, expected).allSatisfy { abs($0 - $1) <= max(12, $1 * 0.03) }, detail: surround?.text ?? "no result")
        // The clock's speed once playing, against the page's own clock.
        let fast = try? await page.evaluateJavaScript("playFile('aac.m4a', 2, 2, 2)")
        check("playbackRate 2 plays twice as fast", abs((fast?["rate"].doubleValue ?? 0) - 2) < 0.15,
              detail: fast?.text ?? "no result")
        let slow = try? await page.evaluateJavaScript("playFile('aac.m4a', 2, 2, 0.5)")
        check("playbackRate 0.5 plays at half speed", abs((slow?["rate"].doubleValue ?? 0) - 0.5) < 0.05,
              detail: slow?.text ?? "no result")
        let immediate = try? await page.evaluateJavaScript("playImmediately('aac.m4a')")
        check("play() right after setting src waits for the takeover and plays",
              immediate?.stringValue == "played", detail: immediate?.text ?? "no result")
        let detached = try? await page.evaluateJavaScript("playDetached('aac.m4a')")
        check("new Audio(url), never in the document, gets canplay and plays", detached?.stringValue == "played",
              detail: detached?.text ?? "no result")
        let failed = try? await page.evaluateJavaScript("failedAppend()")
        check("an append the shim cannot decode fails as a corrupt append does",
              failed?.stringValue == "error,updateend", detail: failed?.text ?? "no result")
    }

    /// Five seconds of tone in each codec AVFoundation encodes, as files
    /// and as fragmented MP4 segments. AVFoundation has no AC-3, E-AC-3 or
    /// xHE-AAC encoder, so those are checked for support only.
    static func makeSystemMedia() async throws -> [String: Data] {
        var files: [String: Data] = [:]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-selftest-media-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stereo = [440.0, 440]
        let variants: [(String, AudioFormatID, [Double], Int)] = [
            ("aac.m4a", kAudioFormatMPEG4AAC, stereo, 16), ("he.m4a", kAudioFormatMPEG4AAC_HE, stereo, 16),
            ("hev2.m4a", kAudioFormatMPEG4AAC_HE_V2, stereo, 16), ("alac.m4a", kAudioFormatAppleLossless, [440, 660], 16),
            ("alac24.m4a", kAudioFormatAppleLossless, [440, 660], 24),
            ("aac51.m4a", kAudioFormatMPEG4AAC, [500, 750, 1000, 62.5, 1250, 1500], 16),
        ]
        for (name, format, frequencies, bits) in variants {
            let url = directory.appendingPathComponent(name)
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            try await writeTone(with: writer, format: format, frequencies: frequencies, bits: bits)
            files["/media/\(name)"] = try Data(contentsOf: url)
        }
        files["/media/aac.aac"] = try adts(from: files["/media/aac.m4a"] ?? Data())
        for (prefix, format) in [("aac", kAudioFormatMPEG4AAC), ("he", kAudioFormatMPEG4AAC_HE)] {
            let writer = AVAssetWriter(contentType: .mpeg4Movie)
            writer.outputFileTypeProfile = .mpeg4AppleHLS
            writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            writer.initialSegmentStartTime = .zero
            let segments = SegmentCollector()
            writer.delegate = segments
            try await writeTone(with: writer, format: format, frequencies: stereo, bits: 16)
            files["/media/\(prefix)-init.mp4"] = segments.initialization
            for (index, data) in segments.media.enumerated() { files["/media/\(prefix)-\(index).m4s"] = data }
            files["/media/\(prefix)-count"] = Data(String(segments.media.count).utf8)
        }
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

    /// The AAC packets of an `.m4a` as ADTS, read back with AVFoundation.
    private static func adts(from m4a: Data) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-selftest-\(UUID().uuidString).m4a")
        try m4a.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var data = Data()
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let count = CMSampleBufferGetNumSamples(sample)
            var offset = 0
            for index in 0..<count {
                let size = CMSampleBufferGetSampleSize(sample, at: index)
                var packet = [UInt8](repeating: 0, count: size)
                CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: size, destination: &packet)
                offset += size
                // AAC-LC (profile 1), 48 kHz (index 3), two channels.
                let length = size + 7
                data.append(contentsOf: [0xff, 0xf1, UInt8((1 << 6) | (3 << 2)), UInt8((2 << 6) | (length >> 11)),
                                         UInt8((length >> 3) & 0xff), UInt8(((length & 7) << 5) | 0x1f), 0xfc])
                data.append(contentsOf: packet)
            }
        }
        return data
    }

    private static func writeTone(with writer: AVAssetWriter, format: AudioFormatID, frequencies: [Double], bits: Int) async throws {
        let rate = 48000.0
        let channels = frequencies.count
        var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        if format == kAudioFormatAppleLossless { settings[AVEncoderBitDepthHintKey] = bits }
        if channels == 6 {
            var layout = AudioChannelLayout(mChannelLayoutTag: kAudioChannelLayoutTag_AAC_5_1, mChannelBitmap: [],
                                            mNumberChannelDescriptions: 0, mChannelDescriptions: AudioChannelDescription())
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        // The input in WAVE order (L R C LFE Ls Rs for 5.1).
        var inputLayout = AudioChannelLayout(
            mChannelLayoutTag: channels == 6 ? kAudioChannelLayoutTag_MPEG_5_1_A : kAudioChannelLayoutTag_Stereo,
            mChannelBitmap: [], mNumberChannelDescriptions: 0, mChannelDescriptions: AudioChannelDescription())
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &inputLayout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
        guard let formatDescription else { throw CocoaError(.fileWriteUnknown) }
        let total = Int(rate * 5)
        var sample = 0
        while sample < total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let count = min(1024, total - sample)
            var pcm = [Int32](repeating: 0, count: count * channels)
            for i in 0..<count {
                for c in 0..<channels {
                    pcm[i * channels + c] = Int32(sin(2 * .pi * frequencies[c] * Double(sample + i) / rate) * 0.3 * Double(Int32.max))
                }
            }
            let bytes = count * 4 * channels
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            guard let block else { throw CocoaError(.fileWriteUnknown) }
            pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
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

/// `selftest://media/`: the page both instances load, and the media the
/// probe made.
struct SystemMediaPages: CefSchemeHandler {
    /// The media, by path. Set before any page loads.
    nonisolated(unsafe) static var files: [String: Data] = [:]

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        guard let path = request.url?.path else { return .notFound() }
        if path == "/index.html" { return CefSchemeResponse(mimeType: "text/html", body: Data(Self.page.utf8)) }
        guard let data = Self.files[path] else { return .notFound() }
        let type = path.hasSuffix(".m4a") ? "audio/mp4" : path.hasSuffix(".aac") ? "audio/aac" : "application/octet-stream"
        return CefSchemeResponse(mimeType: type, body: data)
    }

    /// `playMSE`, `playFile`, `support`, `inspectFunctions` and `failedAppend`
    /// resolve to what they measured.
    static let page = """
        <title>media</title>
        <script>
        const wait = (ms) => new Promise(r => setTimeout(r, ms));
        async function listen(a, seconds, channels = 2) {
          const ctx = new AudioContext();
          const source = ctx.createMediaElementSource(a);
          const split = ctx.createChannelSplitter(channels);
          source.connect(split); source.connect(ctx.destination);
          const analysers = [];
          for (let c = 0; c < channels; c++) { const an = ctx.createAnalyser(); an.fftSize = 8192; split.connect(an, c); analysers.push(an); }
          await ctx.resume(); const start = a.currentTime; const t0 = performance.now(); await a.play();
          const buf = new Float32Array(8192), spectrum = new Float32Array(4096); let peak = 0, mark = null; const peaks = new Array(channels).fill(0);
          for (let i = 0; i < seconds * 10; i++) {
            await wait(100);
    if (i === 4) mark = [a.currentTime, performance.now()];
            analysers.forEach((an, c) => {
              an.getFloatTimeDomainData(buf); let e = 0; for (const v of buf) e += v * v; peak = Math.max(peak, Math.sqrt(e / buf.length));
              an.getFloatFrequencyData(spectrum); let best = 0; for (let k = 1; k < spectrum.length; k++) if (spectrum[k] > spectrum[best]) best = k;
              peaks[c] = Math.round(best * ctx.sampleRate / an.fftSize);
            });
          }
          const rate = mark ? (a.currentTime - mark[0]) / ((performance.now() - mark[1]) / 1000) : 0;
  return { advanced: a.currentTime - start, wall: (performance.now() - t0) / 1000, rate, rms: peak, frequencies: peaks, ctx };
        }
        async function appendAll(sb, parts) {
          for (const p of parts) await new Promise((res, rej) => {
            sb.addEventListener('updateend', res, { once: true });
            sb.addEventListener('error', () => rej(new Error('append failed')), { once: true });
            sb.appendBuffer(p);
          });
        }
        const get = async (p) => new Uint8Array(await (await fetch('/media/' + p)).arrayBuffer());
        async function playMSE(prefix, type = 'audio/mp4; codecs="mp4a.40.2"') {
          const a = document.createElement('audio'); document.body.append(a);
          const ms = new MediaSource(); a.src = URL.createObjectURL(ms);
          await new Promise(r => ms.addEventListener('sourceopen', r, { once: true }));
          const sb = ms.addSourceBuffer(type);
          const events = []; for (const e of ['updatestart', 'update', 'updateend', 'error', 'abort']) sb.addEventListener(e, () => events.push(e));
          const count = +(await (await fetch(`/media/${prefix}-count`)).text());
          const parts = [await get(`${prefix}-init.mp4`)]; for (let i = 0; i < count; i++) parts.push(await get(`${prefix}-${i}.m4s`));
          const t0 = performance.now(); await appendAll(sb, parts); const appendMs = performance.now() - t0;
          ms.endOfStream();
          const heard = await listen(a, 1.5); heard.ctx.close(); a.pause();
          return { ranges: sb.buffered.length, end: sb.buffered.end(0), advanced: heard.advanced, rms: heard.rms, frequencies: heard.frequencies,
                   sameObject: ms.sourceBuffers[0] === sb, proto: Object.getPrototypeOf(sb) === SourceBuffer.prototype,
                   events: events.join(','), appendMs: Math.round(appendMs) };
        }
        async function playFile(name, channels = 2, seconds = 1.5, rate = 1) {
          const a = document.createElement('audio'); document.body.append(a);
          a.src = '/media/' + name;
          await Promise.race([new Promise(r => a.addEventListener('canplay', r, { once: true })), wait(8000)]);
          if (a.error) return { error: a.error.code, message: a.error.message };
          a.playbackRate = rate;
          const heard = await listen(a, seconds, channels);
          a.currentTime = 3;
          await new Promise(r => a.addEventListener('seeked', r, { once: true }));
          const seekedAt = a.currentTime;
          heard.ctx.close(); a.pause();
          return { error: null, advanced: heard.advanced, wall: heard.wall, rate: heard.rate, rms: heard.rms, frequencies: heard.frequencies, seekedAt,
                   src: a.src, currentSrc: a.currentSrc, duration: a.duration };
        }
        async function failedAppend() {
          const a = document.createElement('audio'); document.body.append(a);
          const ms = new MediaSource(); a.src = URL.createObjectURL(ms);
          await new Promise(r => ms.addEventListener('sourceopen', r, { once: true }));
          const sb = ms.addSourceBuffer('audio/mp4; codecs="mp4a.40.2"');
          // An initialization segment whose audio is in a codec nothing decodes.
          const init = await get('aac-init.mp4');
          for (let i = 0; i + 4 < init.length; i++) if (init[i] === 0x6d && init[i + 1] === 0x70 && init[i + 2] === 0x34 && init[i + 3] === 0x61) { init[i + 3] = 0x78; break; }
          const events = []; for (const e of ['error', 'updateend']) sb.addEventListener(e, () => events.push(e));
          sb.appendBuffer(init);
          await new Promise(r => sb.addEventListener('updateend', r, { once: true }));
          return events.join(',');
        }
        async function playDetached(name) {
          const a = new Audio('/media/' + name);
          await Promise.race([new Promise(r => a.addEventListener('canplay', r, { once: true })), wait(8000)]);
          try { await a.play(); } catch (e) { return 'rejected ' + e.name; }
          for (let i = 0; i < 50 && a.currentTime < 0.3; i++) await wait(100);
          const t = a.currentTime; a.pause(); return t >= 0.3 ? 'played' : 'stalled ' + t;
        }
        async function playImmediately(name) {
          const a = document.createElement('audio'); document.body.append(a);
          a.src = '/media/' + name;
          try { await a.play(); } catch (e) { return 'rejected ' + e.name; }
          for (let i = 0; i < 50 && a.currentTime < 0.3; i++) await wait(100);
          const t = a.currentTime; a.pause(); return t >= 0.3 ? 'played' : 'stalled ' + t;
        }
        function support() {
          const t = (s) => MediaSource.isTypeSupported(s);
          return {
            aac: t('audio/mp4; codecs="mp4a.40.2"'), he: t('audio/mp4; codecs="mp4a.40.5"'), xhe: t('audio/mp4; codecs="mp4a.40.42"'),
            alac: t('audio/mp4; codecs="alac"'), ac3: t('audio/mp4; codecs="ac-3"'), ec3: t('audio/mp4; codecs="ec-3"'),
            h264: t('video/mp4; codecs="avc1.640028"'), mixed: t('video/mp4; codecs="avc1.640028,mp4a.40.2"'),
            canPlay: document.createElement('audio').canPlayType('audio/mp4; codecs="mp4a.40.2"'),
            canPlayBare: document.createElement('audio').canPlayType('audio/mp4'),
          };
        }
        function inspectFunctions() {
          const fns = { isTypeSupported: MediaSource.isTypeSupported, addSourceBuffer: MediaSource.prototype.addSourceBuffer,
            endOfStream: MediaSource.prototype.endOfStream, appendBuffer: SourceBuffer.prototype.appendBuffer,
            remove: SourceBuffer.prototype.remove, abort: SourceBuffer.prototype.abort, changeType: SourceBuffer.prototype.changeType,
            canPlayType: HTMLMediaElement.prototype.canPlayType,
            updating: Object.getOwnPropertyDescriptor(SourceBuffer.prototype, 'updating').get,
            src: Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src').get,
            decodingInfo: MediaCapabilities.prototype.decodingInfo, Audio };
          const out = {};
          for (const [k, f] of Object.entries(fns)) {
            let constructs = false; try { new f(); constructs = true; } catch (e) { constructs = e instanceof TypeError ? false : String(e); }
            out[k] = { toString: Function.prototype.toString.call(f), name: f.name, length: f.length, hasPrototype: 'prototype' in f, constructs };
          }
          out.globals = Object.getOwnPropertyNames(window).filter(n => /shim|cefswift|native|flac/i.test(n));
          try { MediaSource.prototype.addSourceBuffer.call({}, 'x'); } catch (e) { out.illegal = e.constructor.name + ': ' + e.message; }
          try { new MediaSource().addSourceBuffer('audio/mp4; codecs="mp4a.40.2"'); } catch (e) { out.closedAdd = e.name + ': ' + e.message; }
          return out;
        }
        </script>
        """
}
