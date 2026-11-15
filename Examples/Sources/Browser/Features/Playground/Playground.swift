import CefSwiftUI
import SwiftUI

/// `browser://playground/`, Help › Playground: pages for trying how the
/// browser handles popups, downloads, leaving a page, load errors and
/// protected media.
struct Playground: BrowserFeature {
    static let url = URL(string: "browser://playground/")!

    func start(_ controller: BrowserController) {
        BrowserPages.register(host: "playground", Pages())
    }

    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(after: .help) {
            Button("Playground") { controller.openTab(url: Self.url) }
        }
    }

    private struct Pages: CefSchemeHandler {
        func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
            switch request.url?.path {
            case "/popup.html": BrowserPages.html(Playground.popupPage)
            case "/leave.html": BrowserPages.html(Playground.leavePage)
            case "/widevine.html": BrowserPages.html(Playground.widevinePage)
            case "/report.txt":
                CefSchemeResponse(
                    headers: ["Content-Disposition": "attachment; filename=\"report.txt\""],
                    mimeType: "text/plain", body: Data(String(repeating: "CefSwift\n", count: 4096).utf8))
            default: BrowserPages.html(Playground.indexPage)
            }
        }
    }

    private nonisolated static let indexPage = """
        <title>Playground</title>
        <h1>Playground</h1>
        <p>Pages that exercise how the browser handles popups, downloads, leaving and protected media.</p>
        <div class="actions">
          <button onclick="openPopup()">Open a popup<small>window.open at 420 × 360</small></button>
          <button onclick="window.open('popup.html', 'any', 'popup')">Open a popup<small>at the default size</small></button>
          <a class="button" href="popup.html" target="_blank">Open in a new tab<small>a link with target=_blank</small></a>
          <a class="button" href="report.txt">Download a file<small>served as an attachment</small></a>
          <a class="button" href="leave.html">Page that asks before leaving<small>beforeunload</small></a>
          <a class="button" href="https://nonexistent.invalid/">Unreachable site<small>shows a load error</small></a>
          <a class="button" href="widevine.html">Widevine test stream<small>Google's test stream and licence server</small></a>
          <a class="button" href="\(fairPlayTestPlayer)">FairPlay test stream<small>Axinom's player: View › Open in WebKit, then Load</small></a>
        </div>
        <script>
          function openPopup() { return !!window.open('popup.html', 'sized', 'width=420,height=360'); }
        </script>
        """

    /// Axinom's public FairPlay test vector in their Shaka-based player,
    /// with the token Axinom publishes for it.
    private nonisolated static let fairPlayTestPlayer = [
        "https://tools.axinom.com/players/Shaka?url=https%3A%2F%2Fmedia.axprod.net%2FTestVectors%2FHls%2Fprot",
        "ected_hls_1080p_h264_singlekey%2Fmanifest.m3u8&license=https%3A%2F%2Fdrm-fairplay-licensing.axprod.n",
        "et%2FAcquireLicense&token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ2ZXJzaW9uIjogMSwKImNvbV9rZXlfaWQiO",
        "iAiZjM0ZjgzZWMtZTQyNS00OTYzLWExODMtYjRkNDAwYmNlNDQ0IiwKIm1lc3NhZ2UiOiB7CiAgInR5cGUiOiAiZW50aXRsZW1lb",
        "nRfbWVzc2FnZSIsCiAgInZlcnNpb24iOiAyLAogICJsaWNlbnNlIjogewogICAgImFsbG93X3BlcnNpc3RlbmNlIjogdHJ1ZQogI",
        "H0sCiAgImNvbnRlbnRfa2V5c19zb3VyY2UiOiB7CiAgICAiaW5saW5lIjogWwogICAgICB7CiAgICAgICAgImlkIjogIjQwNjBhO",
        "DY1LTg4NzgtNDI2Ny05Y2JmLTkxYWU1YmFlMWU3MiIsCiAgICAgICAgImVuY3J5cHRlZF9rZXkiOiAieE5LNVNvRzRseGdHbGpRY",
        "2ZMOVRXQT09IiwKICAgICAgICAiaXYiOiAiTkJOYUpPcGI3MnNTYzBkSXFJejJQdz09IiwKICAgICAgICAidXNhZ2VfcG9saWN5I",
        "jogIlBvbGljeSBBIgogICAgICB9CiAgICBdCiAgfSwKICAiY29udGVudF9rZXlfdXNhZ2VfcG9saWNpZXMiOiBbCiAgICB7CiAgI",
        "CAgICJuYW1lIjogIlBvbGljeSBBIiwKICAgICAgInBsYXlyZWFkeSI6IHsKICAgICAgICAibWluX2RldmljZV9zZWN1cml0eV9sZ",
        "XZlbCI6IDE1MCwKICAgICAgICAicGxheV9lbmFibGVycyI6IFsKICAgICAgICAgICI3ODY2MjdEOC1DMkE2LTQ0QkUtOEY4OC0wO",
        "EFFMjU1QjAxQTciCiAgICAgICAgXQogICAgICB9CiAgICB9CiAgXQp9fQ.3Ti5rkzgw77GOXIpZWqNBUX16DXvph_NiJPCejrDSt",
        "A&certUrl=https%3A%2F%2Ftools.axinom.com%2FFPScert%2Ffairplay.cer&thumbnailVtt=&keySystem=com.apple.",
        "fps&videoRobust=Default&audioRobust=Default",
    ].joined()

    /// Shaka Player playing Google's Widevine-protected "Angel One" test
    /// stream (VP9 in WebM, which Chromium in CefSwift decodes) with
    /// Widevine's test licence server.
    private nonisolated static let widevinePage = """
        <title>Widevine Test Stream</title>
        <h1>Widevine test stream</h1>
        <p id="status">Loading Shaka Player…</p>
        <video id="video" controls autoplay muted style="width: 100%; max-width: 720px; background: #000"></video>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/shaka-player/4.16.0/shaka-player.compiled.js"></script>
        <script>
          const status = document.getElementById('status');
          (async () => {
            if (!window.shaka) { status.textContent = 'Shaka Player did not load (offline?).'; return; }
            shaka.polyfill.installAll();
            const player = new shaka.Player();
            await player.attach(document.getElementById('video'));
            player.configure({ drm: { servers: { 'com.widevine.alpha': 'https://proxy.uat.widevine.com/proxy' } } });
            try {
              await player.load('https://storage.googleapis.com/shaka-demo-assets/angel-one-widevine/dash.mpd');
              const track = player.getVariantTracks().find(t => t.active);
              status.textContent = 'Playing with ' + player.keySystem() + ' (' + player.drmInfo().videoRobustness +
                '), ' + track.videoCodec + ' ' + track.width + '×' + track.height + '.';
            } catch (error) {
              status.textContent = 'Could not play: Shaka error ' + error.code +
                (error.code === 6001 ? ' (no Widevine yet: Chromium may still be downloading it; reload in a moment)' : '');
            }
          })();
        </script>
        """

    private nonisolated static let popupPage = """
        <title>Popup</title>
        <h1>Popup</h1>
        <p id="size"></p>
        <p>Opened by <span id="opener"></span>.</p>
        <div class="actions" style="grid-template-columns: 1fr">
          <button onclick="window.close()">Close<small>the page calls window.close()</small></button>
        </div>
        <script>
          const update = () => { document.getElementById('size').textContent = innerWidth + ' × ' + innerHeight; };
          addEventListener('resize', update); update();
          document.getElementById('opener').textContent = window.opener ? window.opener.location.href : 'no one';
        </script>
        """

    private nonisolated static let leavePage = """
        <title>Unsaved Changes</title>
        <h1>Unsaved changes</h1>
        <p>Click anywhere on the page, then close the tab or navigate away: the browser asks first.</p>
        <script>
          addEventListener('beforeunload', event => { event.preventDefault(); event.returnValue = ''; });
        </script>
        """
}
