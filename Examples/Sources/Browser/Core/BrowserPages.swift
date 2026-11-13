import CefSwiftUI
import Foundation

/// The browser's own pages, served from `browser://<host>/`. The scheme is
/// the browser's; each page belongs to the feature that serves it
/// (`StartPage`, the About page of `ChromiumPages`, `Playground`), which
/// registers its host with ``register(host:_:)``.
enum BrowserPages {
    static let scheme = "browser"

    /// Serves `browser://<host>/…` with `handler`.
    @MainActor static func register(host: String, _ handler: some CefSchemeHandler) {
        CefRuntime.shared.registerSchemeHandler(scheme: scheme, domain: host, handler: handler)
    }

    /// Whether `url` is one of the browser's or Chromium's own pages.
    static func isInternal(_ url: URL?) -> Bool {
        url?.scheme == "chrome" || url?.scheme == scheme
    }

    /// An HTML page in the browser's own style.
    static func html(_ page: String) -> CefSchemeResponse {
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
}
