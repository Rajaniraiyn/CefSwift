import CefKit
import Foundation

/// Serves the launcher:// demo pages and registers a bridge function. The
/// pages are intentionally tiny, self-contained HTML so the demos work fully
/// offline.
enum LauncherDemoPage {
    @MainActor private static var didRegister = false

    /// Registers the launcher:// scheme handler + a `ping` bridge function.
    /// Idempotent; call once after CEF init.
    @MainActor static func registerSchemeHandler() {
        guard !didRegister else { return }
        didRegister = true
        CefRuntime.shared.registerSchemeHandler(scheme: "launcher", handler: Handler())
        CefRuntime.shared.bridge.register("ping") { (message: String) -> String in
            "Swift received: \"\(message.prefix(120))\" @ "
                + Date.now.formatted(date: .omitted, time: .standard)
        }
    }

    /// URL for a given page path (e.g. `popups`, `dialogs`, `downloads`, `bridge`).
    static func url(_ path: String) -> URL { URL(string: "launcher://app/\(path)")! }

    private struct Handler: CefSchemeHandler {
        func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
            let path = request.url?.lastPathComponent ?? ""
            let html: String
            switch path {
            case "popups": html = popupsHTML
            case "dialogs": html = dialogsHTML
            case "downloads": html = downloadsHTML
            case "bridge": html = bridgeHTML
            default: html = "<h1>launcher demo</h1>"
            }
            return CefSchemeResponse(status: 200, mimeType: "text/html", body: Data(html.utf8))
        }
    }

    private static let head = """
        <meta charset="utf-8">
        <style>
          body { font: 15px -apple-system, system-ui, sans-serif; margin: 32px; color: #1d1d1f;
                 line-height: 1.5; }
          h1 { font-size: 22px; } h2 { font-size: 17px; margin-top: 28px; }
          a, button { font-size: 15px; }
          button { padding: 8px 16px; border-radius: 8px; border: none;
                   background: #0071e3; color: #fff; cursor: pointer; margin: 4px 0; }
          .row { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; margin: 8px 0; }
          .hint { color: #6e6e73; font-size: 13px; }
          #out { margin-top: 16px; padding: 12px; background: #f5f5f7; border-radius: 8px;
                 min-height: 2em; white-space: pre-wrap; }
        </style>
        """

    /// Various link/popup types that drive the window-open disposition handler.
    static let popupsHTML = """
        <!DOCTYPE html><html><head><title>Popups & New Tabs</title>\(head)</head><body>
        <h1>Popups &amp; New Tabs</h1>
        <p class="hint">These exercise the Electron-style window-open handler. In the OSR
        hosting mode the target loads in-place (no native popup is ever created);
        in the Chrome Browser shell they open as foreground/background tabs.</p>

        <h2>Links</h2>
        <div class="row">
          <a href="https://example.com" target="_blank">target=_blank link</a>
          <span class="hint">— ⌘-click or middle-click for a background tab</span>
        </div>
        <div class="row"><a href="https://www.wikipedia.org" target="_blank">another _blank link</a></div>

        <h2>window.open</h2>
        <div class="row">
          <button onclick="window.open('https://example.com', '_blank')">window.open(url)</button>
          <button onclick="window.open('https://example.com', 'named', 'width=640,height=480')">
            window.open with features</button>
        </div>

        <h2>Download</h2>
        <div class="row">
          <a href="data:text/plain;charset=utf-8,Hello%20from%20CefSwift%20Launcher!"
             download="cefswift-launcher.txt">download a text file</a>
        </div>
        </body></html>
        """

    static let dialogsHTML = """
        <!DOCTYPE html><html><head><title>Permissions & JS Dialogs</title>\(head)</head><body>
        <h1>Permissions &amp; JS Dialogs</h1>
        <h2>JavaScript dialogs</h2>
        <div class="row">
          <button onclick="alert('This is a native NSAlert presented by CefSwift.')">alert()</button>
          <button onclick="document.getElementById('out').textContent =
            'confirm() → ' + confirm('Proceed?')">confirm()</button>
          <button onclick="document.getElementById('out').textContent =
            'prompt() → ' + prompt('Your name?', 'Ada')">prompt()</button>
        </div>
        <h2>Permission request</h2>
        <div class="row">
          <button onclick="navigator.geolocation.getCurrentPosition(
            p => document.getElementById('out').textContent = 'granted: ' + p.coords.latitude,
            e => document.getElementById('out').textContent = 'denied/error: ' + e.message)">
            Request geolocation</button>
          <span class="hint">— routed through the permission delegate (denied by default)</span>
        </div>
        <div id="out">results appear here</div>
        </body></html>
        """

    static let downloadsHTML = """
        <!DOCTYPE html><html><head><title>Downloads</title>\(head)</head><body>
        <h1>Downloads</h1>
        <p class="hint">Clicking a download link triggers the download delegate, which
        saves to ~/Downloads by default.</p>
        <div class="row">
          <a href="data:application/octet-stream;base64,Q2VmU3dpZnQgTGF1bmNoZXIgZG93bmxvYWQgZGVtbyE="
             download="cefswift-download-demo.bin">download a binary file</a>
        </div>
        <div class="row">
          <a href="data:text/csv;charset=utf-8,a,b,c%0A1,2,3%0A4,5,6" download="data.csv">download a CSV</a>
        </div>
        </body></html>
        """

    static let bridgeHTML = """
        <!DOCTYPE html><html><head><title>Custom Scheme + JS Bridge</title>
        <script>\(CefBridge.javascriptShim)</script>\(head)</head><body>
        <h1>Custom Scheme + JS Bridge</h1>
        <p class="hint">This page is served over the <code>launcher://</code> custom scheme and
        calls a Swift function via <code>window.cefSwift.invoke</code>.</p>
        <div class="row"><button onclick="ping()">Call Swift ping()</button></div>
        <div id="out">waiting for first round-trip…</div>
        <script>
          let n = 0;
          async function ping() {
            n += 1;
            try {
              const reply = await window.cefSwift.invoke('ping', 'hello #' + n);
              document.getElementById('out').textContent = reply;
            } catch (e) { document.getElementById('out').textContent = 'bridge error: ' + e.message; }
          }
          ping();
        </script>
        </body></html>
        """
}
