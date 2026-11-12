import AppKit
@_spi(Testing) import CefKit
import WebKit

/// CefSystemBrowser: pages in the system's WebKit, with FairPlay.
extension SelfTest {
    static func systemEngineChecks() async {
        var options = CefSystemBrowser.Options()
        options.userScripts = [CefUserScript(source: "window.__injected = 42;")]
        let browser = CefSystemBrowser(options: options)
        browser.nativeView.frame = window.contentView!.bounds
        window.contentView!.addSubview(browser.nativeView)
        defer {
            browser.close()
            browser.nativeView.removeFromSuperview()
        }
        let base = URL(string: "https://selftest.invalid/")!
        browser.loadHTML("<title>system one</title><p>needle</p>", baseURL: base)
        check("system engine: loads and reports its title",
              await waitUntil { browser.title == "system one" && !browser.isLoading }, detail: browser.title)
        await expect("system engine: evaluateJavaScript awaits a promise") {
            try await browser.evaluateJavaScript("new Promise(r => setTimeout(() => r(6 * 7), 10))").intValue == 42
        }
        await expect("system engine: evaluateJavaScript throws the page's exception") {
            do {
                try await browser.evaluateJavaScript("(() => { throw new Error('boom') })()")
                return false
            } catch let error as CefJavaScriptError {
                return error.message.contains("boom")
            }
        }
        // The same inputs as Chromium's evaluateJavaScript: classic scripts.
        await expect("system engine: evaluateJavaScript value") {
            try await browser.evaluateJavaScript("1 + 2").intValue == 3
        }
        await expect("system engine: evaluateJavaScript statements give the last value") {
            try await browser.evaluateJavaScript("var a = 2; function twice(x) { return 2 * x }; twice(a) + 1").intValue == 5
        }
        await expect("system engine: evaluateJavaScript declarations stay local to the call") {
            let first = try await browser.evaluateJavaScript("let local = 7; local").intValue
            let second = try await browser.evaluateJavaScript("let local = 8; local").intValue
            return first == 7 && second == 8
        }
        await expect("system engine: evaluateJavaScript typed") {
            struct Person: Decodable { var name: String }
            return try await browser.evaluateJavaScript("({name: 'Grace'})", as: Person.self).name == "Grace"
        }
        await expect("system engine: evaluateJavaScript top-level throw throws") {
            do {
                try await browser.evaluateJavaScript("throw new Error('boom')")
                return false
            } catch let error as CefJavaScriptError {
                return error.message.contains("boom")
            }
        }
        await expect("system engine: evaluateJavaScript rejected promise throws") {
            do {
                try await browser.evaluateJavaScript("Promise.reject(new Error('later boom'))")
                return false
            } catch let error as CefJavaScriptError {
                return error.message.contains("later boom")
            }
        }
        await expect("system engine: evaluateJavaScript runs on a page whose CSP forbids eval") {
            browser.loadHTML(
                "<meta http-equiv=\"Content-Security-Policy\" content=\"script-src 'none'\"><title>strict</title>",
                baseURL: URL(string: "https://strict.selftest.invalid/")!)
            guard await waitUntil({ browser.title == "strict" && !browser.isLoading }) else { return false }
            return try await browser.evaluateJavaScript("var b = 20; b + 1").intValue == 21
        }
        browser.loadHTML("<title>system one</title><p>needle</p>", baseURL: base)
        _ = await waitUntil { browser.title == "system one" && !browser.isLoading }
        await expect("system engine: user script ran before the page") {
            try await browser.evaluateJavaScript("window.__injected").intValue == 42
        }
        check("system engine: find", await browser.find("needle"))
        await expect("system engine: identifies as Safari") {
            let agent = try await browser.evaluateJavaScript("navigator.userAgent").stringValue ?? ""
            return agent.contains("Version/") && agent.hasSuffix("Safari/605.1.15")
        }
        await expect("system engine: FairPlay (com.apple.fps) with H.264") {
            try await browser.evaluateJavaScript("""
                navigator.requestMediaKeySystemAccess('com.apple.fps', [{
                  initDataTypes: ['cenc'],
                  videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }],
                }]).then(() => 'OK', e => e.name)
                """).stringValue == "OK"
        }
        await expect("system engine: plays H.264 and AAC") {
            try await browser.evaluateJavaScript("""
                [document.createElement('video').canPlayType('video/mp4; codecs="avc1.42E01E"'),
                 MediaSource.isTypeSupported('audio/mp4; codecs="mp4a.40.2"')]
                """) == ["probably", true]
        }

        check("system engine: streaming sites prefer the system engine",
              CefSystemBrowser.prefersSystemEngine(for: URL(string: "https://www.netflix.com/browse")!)
                  && CefSystemBrowser.prefersSystemEngine(for: URL(string: "https://tv.apple.com/")!)
                  && !CefSystemBrowser.prefersSystemEngine(for: URL(string: "https://example.com/")!)
                  && !CefSystemBrowser.prefersSystemEngine(for: URL(string: "https://notnetflix.com/")!))

        let cookieSite = URL(string: "https://cookies.selftest.invalid/")!
        CefProfile.default.setCookie(HTTPCookie(properties: [
            .name: "handoff", .value: "1", .domain: "cookies.selftest.invalid", .path: "/", .secure: "TRUE",
        ])!)
        let copied = await browser.importCookies(from: .default, for: cookieSite)
        let webKitCookies = await browser.nativeView.configuration.websiteDataStore.httpCookieStore.allCookies()
        check("system engine: imports a Chromium profile's cookies for a site",
              copied >= 1 && webKitCookies.contains { $0.name == "handoff" && $0.domain.hasSuffix("cookies.selftest.invalid") },
              detail: "copied \(copied); WebKit has \(webKitCookies.map { "\($0.name)@\($0.domain)" })")
        CefProfile.default.deleteCookies(for: cookieSite)
        await browser.nativeView.configuration.websiteDataStore.removeData(
            ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)

        let privateBrowser = CefSystemBrowser(options: .init(profile: .incognito()))
        let namedBrowser = CefSystemBrowser(options: .init(profile: .persistent(name: "SelfTest System")))
        check("system engine: profiles map to WebKit data stores",
              !privateBrowser.nativeView.configuration.websiteDataStore.isPersistent
                  && namedBrowser.nativeView.configuration.websiteDataStore.isPersistent
                  && namedBrowser.nativeView.configuration.websiteDataStore.identifier
                      == CefSystemBrowser(options: .init(profile: .persistent(name: "SelfTest System")))
                          .nativeView.configuration.websiteDataStore.identifier
                  && browser.nativeView.configuration.websiteDataStore === WKWebsiteDataStore.default())

        await fairPlayPlaybackCheck(in: browser)
    }

    /// Plays Axinom's public FairPlay test stream with Shaka Player: the
    /// licence server must answer and the video must advance. Skips when
    /// the network or the test service is unavailable.
    static func fairPlayPlaybackCheck(in browser: CefSystemBrowser) async {
        browser.load(URL(string: "https://example.com/")!)
        guard await waitUntil(timeout: .seconds(10), { browser.url?.host == "example.com" && !browser.isLoading }) else {
            print("SKIP [environment] system engine: FairPlay playback — example.com did not load (offline?)")
            return
        }
        _ = try? await browser.evaluateJavaScript("location.hash = 'second'")
        check("system engine: back-forward state",
              await waitUntil(timeout: .seconds(5)) { browser.canGoBack && browser.url?.fragment == "second" })
        var failure = ""
        let result: CefJSON?
        do {
            result = try await browser.evaluateJavaScript(Self.fairPlayPlaybackScript)
        } catch {
            result = nil
            failure = "\(error)"
        }
        let license = result?["license"].intValue ?? 0
        let advanced = result?["advanced"].doubleValue ?? 0
        if result == nil || result?["error"].stringValue == "offline" {
            print("SKIP [environment] system engine: FairPlay playback — the player or test stream did not load " +
                  "(\(result?["detail"].stringValue ?? failure))")
            return
        }
        check("system engine: FairPlay test stream plays (licence \(license), \(String(format: "%.1f", advanced)) s played)",
              license == 200 && advanced > 0.5, detail: "\(result.map { "\($0)" } ?? "")")
    }

    /// Axinom's public test vector "protected_hls_1080p_h264_singlekey",
    /// with the token Axinom publishes for it.
    static let fairPlayPlaybackScript = """
        (async () => {
          const token = '\(axinomFairPlayToken)';
          try {
            await new Promise((resolve, reject) => {
              const script = document.createElement('script');
              script.src = 'https://cdnjs.cloudflare.com/ajax/libs/shaka-player/4.16.0/shaka-player.compiled.js';
              script.onload = resolve; script.onerror = reject;
              document.head.appendChild(script);
              setTimeout(reject, 8000);
            });
          } catch (e) { return { error: 'offline', detail: 'Shaka Player did not load' }; }
          document.body.innerHTML = '<video muted playsinline style="width:480px;height:270px"></video>';
          const video = document.querySelector('video');
          shaka.polyfill.installAll();
          const player = new shaka.Player();
          await player.attach(video);
          player.configure({ drm: {
            servers: { 'com.apple.fps': 'https://drm-fairplay-licensing.axprod.net/AcquireLicense' },
            advanced: { 'com.apple.fps': { serverCertificateUri: 'https://tools.axinom.com/FPScert/fairplay.cer' } },
          } });
          let license = 0;
          const engine = player.getNetworkingEngine();
          const LICENSE = shaka.net.NetworkingEngine.RequestType.LICENSE;
          engine.registerRequestFilter((type, request) => {
            if (type === LICENSE) request.headers['X-AxDRM-Message'] = token;
          });
          engine.registerResponseFilter((type, response) => { if (type === LICENSE) license = response.status; });
          try {
            await player.load('https://media.axprod.net/TestVectors/Hls/protected_hls_1080p_h264_singlekey/manifest.m3u8');
          } catch (e) { return { error: 'offline', detail: 'load failed: ' + (e && e.code) }; }
          await video.play().catch(() => {});
          const start = video.currentTime;
          for (let i = 0; i < 40 && video.currentTime - start < 1; i++) await new Promise(r => setTimeout(r, 250));
          const advanced = video.currentTime - start;
          await player.destroy();
          return { license, advanced, keySystem: 'com.apple.fps' };
        })()
        """

    static let axinomFairPlayToken =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ2ZXJzaW9uIjogMSwKImNvbV9rZXlfaWQiOiAiZjM0ZjgzZWMtZTQyNS00OTYzLWEx" +
        "ODMtYjRkNDAwYmNlNDQ0IiwKIm1lc3NhZ2UiOiB7CiAgInR5cGUiOiAiZW50aXRsZW1lbnRfbWVzc2FnZSIsCiAgInZlcnNpb24iOiAy" +
        "LAogICJsaWNlbnNlIjogewogICAgImFsbG93X3BlcnNpc3RlbmNlIjogdHJ1ZQogIH0sCiAgImNvbnRlbnRfa2V5c19zb3VyY2UiOiB7" +
        "CiAgICAiaW5saW5lIjogWwogICAgICB7CiAgICAgICAgImlkIjogIjQwNjBhODY1LTg4NzgtNDI2Ny05Y2JmLTkxYWU1YmFlMWU3MiIs" +
        "CiAgICAgICAgImVuY3J5cHRlZF9rZXkiOiAieE5LNVNvRzRseGdHbGpRY2ZMOVRXQT09IiwKICAgICAgICAiaXYiOiAiTkJOYUpPcGI3" +
        "MnNTYzBkSXFJejJQdz09IiwKICAgICAgICAidXNhZ2VfcG9saWN5IjogIlBvbGljeSBBIgogICAgICB9CiAgICBdCiAgfSwKICAiY29u" +
        "dGVudF9rZXlfdXNhZ2VfcG9saWNpZXMiOiBbCiAgICB7CiAgICAgICJuYW1lIjogIlBvbGljeSBBIiwKICAgICAgInBsYXlyZWFkeSI6" +
        "IHsKICAgICAgICAibWluX2RldmljZV9zZWN1cml0eV9sZXZlbCI6IDE1MCwKICAgICAgICAicGxheV9lbmFibGVycyI6IFsKICAgICAg" +
        "ICAgICI3ODY2MjdEOC1DMkE2LTQ0QkUtOEY4OC0wOEFFMjU1QjAxQTciCiAgICAgICAgXQogICAgICB9CiAgICB9CiAgXQp9fQ." +
        "3Ti5rkzgw77GOXIpZWqNBUX16DXvph_NiJPCejrDStA"
}
