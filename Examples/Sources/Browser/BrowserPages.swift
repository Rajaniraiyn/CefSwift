import CefSwiftUI
import Foundation

/// The browser's own pages, served from `browser://…`: the start page new
/// tabs open with, an About page in place of Chromium's, and a playground
/// for trying popups, downloads and other browser behavior.
struct BrowserPages: CefSchemeHandler {
    static let scheme = "browser"
    static let start = URL(string: "browser://start/")!
    static let about = URL(string: "browser://about/")!
    static let playground = URL(string: "browser://playground/")!
    /// The start page's origin, the only one allowed to call its bridge.
    static let startOrigin = "browser://start"

    /// The page to show instead of one of Chromium's: this app's About page
    /// for Chromium's, which reports on an updater this app doesn't use; and
    /// for the settings pages hidden by `BrowserController.internalPageStyles`
    /// (Chromium's settings open on "You and Google"), Appearance.
    static func replacement(for url: URL?) -> URL? {
        guard let url, url.scheme == "chrome" else { return nil }
        switch (url.host(), url.path) {
        case ("help", _), ("settings", "/help"):
            return about
        case ("settings", ""), ("settings", "/"), ("settings", "/people"), ("settings", "/syncSetup"),
             ("settings", "/defaultBrowser"):
            return URL(string: "chrome://settings/appearance")
        default:
            return nil
        }
    }

    /// Whether `url` is one of the app's or Chromium's own pages.
    static func isInternal(_ url: URL?) -> Bool {
        url?.scheme == "chrome" || url?.scheme == scheme
    }

    /// Whether `url` is the start page, which the address field shows as
    /// empty, like a blank tab.
    static func isStartPage(_ url: URL?) -> Bool {
        url?.scheme == scheme && url?.host() == start.host()
    }

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        switch (request.url?.host(), request.url?.path) {
        case ("start", _): return Self.html(Self.startPage)
        case ("about", _): return Self.html(Self.aboutPage)
        case ("playground", "/popup.html"): return Self.html(Self.popupPage)
        case ("playground", "/leave.html"): return Self.html(Self.leavePage)
        case ("playground", "/widevine.html"): return Self.html(Self.widevinePage)
        case ("playground", "/report.txt"):
            return CefSchemeResponse(
                headers: ["Content-Disposition": "attachment; filename=\"report.txt\""],
                mimeType: "text/plain", body: Data(String(repeating: "CefSwift\n", count: 4096).utf8))
        case ("playground", _): return Self.html(Self.playgroundPage)
        default: return .notFound()
        }
    }

    private static func html(_ page: String) -> CefSchemeResponse {
        CefSchemeResponse(mimeType: "text/html", body: Data((style + page).utf8))
    }

    private static let style = """
        <!doctype html>
        <meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; font: 15px/1.5 -apple-system, system-ui; }
          body { margin: 0; padding: 40px; }
          h1 { font-size: 26px; font-weight: 650; margin: 0 0 6px; }
          p { margin: 4px 0; color: color-mix(in srgb, currentColor 62%, transparent); }
          .actions { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 10px; margin-top: 24px; max-width: 760px; }
          button, a.button { font: inherit; text-align: left; padding: 12px 14px; border-radius: 10px; cursor: default;
            border: 1px solid color-mix(in srgb, currentColor 14%, transparent);
            background: color-mix(in srgb, currentColor 5%, transparent); color: inherit; text-decoration: none; }
          button:hover, a.button:hover { background: color-mix(in srgb, currentColor 10%, transparent); }
          small { display: block; color: color-mix(in srgb, currentColor 55%, transparent); }
        </style>
        """

    /// Frequently visited sites and recent bookmarks as tiles, with the
    /// sites' icons where Chromium has them. The data comes from Swift
    /// through the `startPage` bridge (`BrowserLibrary`), which also says
    /// when bookmarks change.
    private static let startPage = """
        <title>New Tab</title>
        <style>
          body { padding: 72px 40px 40px; }
          main { max-width: 720px; margin: 0 auto; }
          h2 { font-size: 15px; font-weight: 650; margin: 0 0 10px 6px; }
          section { margin-bottom: 36px; }
          [hidden] { display: none !important; }
          .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(88px, 1fr)); gap: 6px; }
          .tile { display: flex; flex-direction: column; align-items: center; gap: 8px; padding: 12px 4px 8px;
            border-radius: 12px; color: inherit; text-decoration: none; cursor: default; min-width: 0; }
          .tile:hover { background: color-mix(in srgb, currentColor 7%, transparent); }
          .monogram { width: 56px; height: 56px; border-radius: 14px; display: grid; place-items: center;
            font-size: 24px; font-weight: 600; color: white; background: hsl(var(--hue) 52% 50%);
            box-shadow: 0 1px 2px rgb(0 0 0 / 0.18), inset 0 0 0 0.5px rgb(255 255 255 / 0.2); }
          .monogram.icon { background: color-mix(in srgb, currentColor 8%, transparent); }
          .monogram.icon img { width: 32px; height: 32px; }
          .name { font-size: 12px; line-height: 1.3; max-width: 100%; overflow: hidden; text-overflow: ellipsis;
            white-space: nowrap; text-align: center; }
          .note { display: flex; gap: 12px; align-items: center; padding: 14px 16px; margin-bottom: 36px;
            border-radius: 12px; background: color-mix(in srgb, currentColor 6%, transparent); }
          .note p { margin: 0; font-size: 13px; }
          .note strong { display: block; font-weight: 600; }
          .empty { margin-left: 6px; font-size: 13px; }
        </style>
        <main>
          <div class="note" id="private" hidden>
            <span style="font-size: 26px">✋</span>
            <p><strong>Private Browsing</strong>This tab doesn’t keep history, cookies or site data once it closes.</p>
          </div>
          <section id="frequent" hidden><h2>Frequently Visited</h2><div class="tiles"></div></section>
          <section id="bookmarks" hidden><h2>Bookmarks</h2><div class="tiles"></div></section>
          <p class="empty" id="empty" hidden>Sites you visit often and pages you bookmark appear here.</p>
        </main>
        <script>
          const hostOf = url => { try { return new URL(url).hostname.replace(/^www\\./, ''); } catch { return url; } };
          const hue = text => [...text].reduce((sum, c) => (sum * 31 + c.charCodeAt(0)) % 360, 7);
          function tile(site) {
            const host = hostOf(site.url);
            const link = document.createElement('a');
            link.className = 'tile';
            link.href = site.url;
            link.title = site.title ? site.title + '\\n' + site.url : site.url;
            const monogram = document.createElement('span');
            monogram.className = 'monogram';
            monogram.style.setProperty('--hue', hue(host));
            if (site.icon) {
              const icon = document.createElement('img');
              icon.src = site.icon;
              icon.alt = '';
              monogram.classList.add('icon');
              monogram.append(icon);
            } else {
              monogram.textContent = (host[0] ?? '?').toUpperCase();
            }
            const name = document.createElement('span');
            name.className = 'name';
            name.textContent = site.title || host;
            link.append(monogram, name);
            return link;
          }
          function fill(id, sites) {
            const section = document.getElementById(id);
            section.querySelector('.tiles').replaceChildren(...sites.map(tile));
            section.hidden = sites.length === 0;
          }
          async function render() {
            const content = await startPage.load();
            document.getElementById('private').hidden = !content.isPrivate;
            fill('frequent', content.frequentlyVisited);
            fill('bookmarks', content.bookmarks);
            document.getElementById('empty').hidden = content.frequentlyVisited.length + content.bookmarks.length > 0;
          }
          render();
          startPage.on('changed', render);
        </script>
        """

    private static let aboutPage = """
        <title>About CefSwift Browser</title>
        <style>
          body { min-height: calc(100vh - 80px); display: grid; place-items: center; }
          main { text-align: center; }
          .icon { font-size: 64px; }
        </style>
        <main>
          <div class="icon">🧭</div>
          <h1>CefSwift Browser</h1>
          <p id="engine"></p>
          <p>Built with CefSwift on the Chromium Embedded Framework.</p>
        </main>
        <script>
          const version = navigator.userAgent.match(/Chrome\\/([\\d.]+)/);
          document.getElementById('engine').textContent = version ? 'Chromium ' + version[1] : '';
        </script>
        """

    private static let playgroundPage = """
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
    private static let fairPlayTestPlayer = [
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
    private static let widevinePage = """
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

    private static let popupPage = """
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

    private static let leavePage = """
        <title>Unsaved Changes</title>
        <h1>Unsaved changes</h1>
        <p>Click anywhere on the page, then close the tab or navigate away: the browser asks first.</p>
        <script>
          addEventListener('beforeunload', event => { event.preventDefault(); event.returnValue = ''; });
        </script>
        """
}
