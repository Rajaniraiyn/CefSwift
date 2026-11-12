import CefSwiftUI
import Foundation

/// The browser's own pages, served from `browser://…`: an About page in
/// place of Chromium's, and a playground for trying popups, downloads and
/// other browser behavior.
struct BrowserPages: CefSchemeHandler {
    static let scheme = "browser"
    static let about = URL(string: "browser://about/")!
    static let playground = URL(string: "browser://playground/")!

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

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        switch (request.url?.host(), request.url?.path) {
        case ("about", _): return Self.html(Self.aboutPage)
        case ("playground", "/popup.html"): return Self.html(Self.popupPage)
        case ("playground", "/leave.html"): return Self.html(Self.leavePage)
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
        <p>Pages that exercise how the browser handles popups, downloads and leaving.</p>
        <div class="actions">
          <button onclick="openPopup()">Open a popup<small>window.open at 420 × 360</small></button>
          <button onclick="window.open('popup.html', 'any', 'popup')">Open a popup<small>at the default size</small></button>
          <a class="button" href="popup.html" target="_blank">Open in a new tab<small>a link with target=_blank</small></a>
          <a class="button" href="report.txt">Download a file<small>served as an attachment</small></a>
          <a class="button" href="leave.html">Page that asks before leaving<small>beforeunload</small></a>
          <a class="button" href="https://nonexistent.invalid/">Unreachable site<small>shows a load error</small></a>
        </div>
        <script>
          function openPopup() { return !!window.open('popup.html', 'sized', 'width=420,height=360'); }
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
