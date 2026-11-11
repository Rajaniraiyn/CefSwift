import CefSwiftUI
import Foundation

/// The browser's own pages, served from `browser://…`. They stand in for
/// Chromium pages this app replaces — here, About.
struct BrowserPages: CefSchemeHandler {
    static let scheme = "browser"
    static let about = URL(string: "browser://about/")!

    /// Chromium's About pages, which report on an updater this app doesn't use.
    static func replacesChromiumPage(_ url: URL?) -> Bool {
        guard let text = url?.absoluteString else { return false }
        return text.hasPrefix("chrome://settings/help") || text.hasPrefix("chrome://help")
    }

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        guard request.url?.host() == "about" else { return .notFound() }
        return CefSchemeResponse(mimeType: "text/html", body: Data(Self.aboutPage.utf8))
    }

    private static let aboutPage = """
        <!doctype html>
        <meta charset="utf-8">
        <title>About CefSwift Browser</title>
        <style>
          :root { color-scheme: light dark; font: 15px/1.5 -apple-system, system-ui; }
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
          main { text-align: center; }
          .icon { font-size: 64px; }
          h1 { font-size: 28px; font-weight: 600; margin: 12px 0 4px; }
          p { margin: 2px 0; color: color-mix(in srgb, currentColor 60%, transparent); }
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
}
