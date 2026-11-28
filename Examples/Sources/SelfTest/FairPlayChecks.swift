import AppKit
@_spi(Testing) import CefKit
import CefProtectedMedia

/// CefProtectedMedia's `CefFairPlay`, in a probe whose default profile has
/// it for `https://cefswift.test` alone: the key system appears there and
/// nowhere else, a playlist that points anywhere but `https` is refused
/// with a media error and the delegate told, and, online, Axinom's public
/// FairPlay test stream gets a licence and plays its audio through the
/// FairPlay service.
extension SelfTest {
    static func fairPlayChecks() async {
        check("fairPlay: the app carries the FairPlay service", CefFairPlay.isServiceAvailable)
        await runProbe("fairPlay", label: "fairPlay", timeout: .seconds(90))
    }

    @MainActor
    final class FairPlayFailures: CefFairPlayDelegate {
        var errors: [CefFairPlayError] = []
        var playing: [Bool] = []
        func fairPlay(_ fairPlay: CefFairPlay, page: CefPage, didFail error: CefFairPlayError) { errors.append(error) }
        func fairPlay(_ fairPlay: CefFairPlay, page: CefPage, didChangePlaying isPlaying: Bool) { playing.append(isPlaying) }
    }

    static func fairPlayProbeChecks() async {
        let fairPlay = CefFairPlay(origins: ["https://cefswift.test"])
        let failures = FairPlayFailures()
        fairPlay.delegate = failures
        fairPlay.install(in: .default)

        // An origin that is not listed: Chromium's own EME, no global.
        let other = CefPage(url: URL(string: "selftest://media/index.html")!)
        let otherView = hostWindowed(other)
        defer {
            other.close(force: true)
            otherView.removeFromSuperview()
        }
        if await loaded(other) {
            let answer = try? await other.evaluateJavaScript(Self.keySystemProbe)
            check("an origin not listed gets no FairPlay and no bridge",
                  answer?["fps"].stringValue == "NotSupportedError" && answer?["bridge"].boolValue == false,
                  detail: answer?.text ?? "no result")
        } else {
            check("the unlisted page loads", false)
        }

        let page = CefPage(url: URL(string: "https://cefswift.test/plain.html")!)
        let view = hostWindowed(page)
        defer {
            page.close(force: true)
            view.removeFromSuperview()
        }
        guard await loaded(page) else {
            check("the listed page loads", false)
            return
        }
        let answer = try? await page.evaluateJavaScript(Self.keySystemProbe)
        check("the listed origin gets com.apple.fps.1_0 through EME",
              answer?["fps"].stringValue == "com.apple.fps.1_0", detail: answer?.text ?? "no result")
        check("the listed origin's other key systems stay Chromium's",
              answer?["clearKey"].stringValue == "org.w3.clearkey", detail: answer?.text ?? "")

        let refused = try? await page.evaluateJavaScript(Self.refusedPlaylistProbe)
        check("a playlist with a file: segment is refused with a media error",
              refused?["error"].intValue == 3 && refused?["opened"].boolValue == false, detail: refused?.text ?? "no result")
        check("the delegate hears why",
              failures.errors.contains { if case .refused(let reason) = $0 { reason.contains("https") } else { false } },
              detail: "\(failures.errors)")

        fairPlay.isEnabled = false
        let off = try? await page.evaluateJavaScript("""
            new Promise(r => setTimeout(r, 300)).then(() => navigator.requestMediaKeySystemAccess('com.apple.fps.1_0',
              [{ initDataTypes: ['skd'], audioCapabilities: [{ contentType: 'audio/mp4' }] }]).then(a => a.keySystem, e => e.name))
            """)
        check("turned off, an open page gets Chromium's answer at once", off?.stringValue == "NotSupportedError",
              detail: off?.text ?? "no result")
        fairPlay.isEnabled = true

        // Online: Axinom's public test stream, audio only, through the service.
        let played = try? await page.evaluateJavaScript(Self.axinomAudioProbe, timeout: .seconds(45))
        let license = played?["license"].intValue ?? 0
        let advanced = played?["advanced"].doubleValue ?? 0
        if played == nil || played?["stage"].stringValue == "offline" {
            skip("Axinom's FairPlay test stream plays through the service", because: "the test stream did not load " +
                 "(\(played?["detail"].stringValue ?? "no result"))", .environment)
        } else {
            check("Axinom's FairPlay test stream gets a licence and plays (licence \(license), \(String(format: "%.1f", advanced)) s)",
                  license == 200 && advanced > 1, detail: played?.text ?? "")
            check("the delegate hears the service play", failures.playing.contains(true), detail: "\(failures.playing)")
        }
    }

    static let keySystemProbe = """
        (async () => {
          const ask = (keySystem) => navigator.requestMediaKeySystemAccess(keySystem,
            [{ initDataTypes: ['skd', 'cenc'], audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }, { contentType: 'audio/webm; codecs="opus"' }] }])
            .then(a => a.keySystem, e => e.name);
          return { fps: await ask('com.apple.fps.1_0'), clearKey: await ask('org.w3.clearkey'), bridge: 'cefswiftFairPlay' in window };
        })()
        """

    static let refusedPlaylistProbe = """
        (async () => {
          const access = await navigator.requestMediaKeySystemAccess('com.apple.fps.1_0', [{ initDataTypes: ['skd'] }]);
          const keys = await access.createMediaKeys();
          await keys.setServerCertificate(new Uint8Array(64).fill(7));
          const audio = document.createElement('audio');
          await audio.setMediaKeys(keys);
          const playlist = '#EXTM3U\\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://k"\\n#EXTINF:4,\\nfile:///etc/hosts\\n#EXT-X-ENDLIST\\n';
          const failed = new Promise(r => audio.addEventListener('error', r, { once: true }));
          audio.src = 'data:application/vnd.apple.mpegurl;base64,' + btoa(playlist);
          await Promise.race([failed, new Promise(r => setTimeout(r, 5000))]);
          return { error: audio.error && audio.error.code, opened: audio.readyState > 0 };
        })()
        """

    /// The audio rendition of Axinom's "protected_hls_1080p_h264_singlekey"
    /// test vector, handed over as a `data:` playlist as Spotify's player
    /// does, with Axinom's certificate and published token.
    static let axinomAudioProbe = """
        (async () => {
          const token = '\(axinomFairPlayToken)';
          const base = 'https://media.axprod.net/TestVectors/Hls/protected_hls_1080p_h264_singlekey/';
          const wait = (ms) => new Promise((r) => setTimeout(r, ms));
          let text, certificate;
          try {
            text = await (await fetch(base + 'audio-en.m3u8')).text();
            certificate = await (await fetch('https://tools.axinom.com/FPScert/fairplay.cer')).arrayBuffer();
          } catch (e) { return { stage: 'offline', detail: String(e) }; }
          const absolute = text.split('\\n').map((line) => (line && !line.startsWith('#') ? new URL(line.trim(), base).href : line)).join('\\n');
          const access = await navigator.requestMediaKeySystemAccess('com.apple.fps.1_0', [{ initDataTypes: ['skd'] }]);
          const keys = await access.createMediaKeys();
          await keys.setServerCertificate(certificate);
          const audio = document.createElement('audio');
          document.body.append(audio);
          await audio.setMediaKeys(keys);
          let license = 0;
          audio.addEventListener('encrypted', async (event) => {
            const session = keys.createSession();
            session.addEventListener('message', async (message) => {
              const response = await fetch('https://drm-fairplay-licensing.axprod.net/AcquireLicense', {
                method: 'POST', headers: { 'X-AxDRM-Message': token }, body: message.message });
              license = response.status;
              await session.update(await response.arrayBuffer());
            });
            await session.generateRequest(event.initDataType, event.initData);
          });
          audio.src = 'data:application/vnd.apple.mpegurl;base64,' + btoa(absolute);
          for (let i = 0; i < 80 && audio.readyState < 4 && !audio.error; i++) await wait(250);
          if (audio.error) return { stage: 'load', error: audio.error.message, license };
          await audio.play();
          const start = audio.currentTime;
          for (let i = 0; i < 40 && audio.currentTime - start < 2 && !audio.error; i++) await wait(250);
          const advanced = audio.currentTime - start;
          audio.pause();
          return { stage: 'played', license, advanced, error: audio.error && audio.error.message };
        })()
        """
}
