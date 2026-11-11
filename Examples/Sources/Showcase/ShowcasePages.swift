import CefSwiftUI
import Foundation

/// The app's own pages, served from `showcase://app/…`. A real app would
/// point `CefDirectorySchemeHandler` at a folder of bundled web resources.
struct ShowcasePages: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        switch request.url?.path {
        case "/bridge.html": page(Self.bridge)
        case "/editor.html": page(Self.editor)
        default: .notFound()
        }
    }

    private func page(_ html: String) -> CefSchemeResponse {
        CefSchemeResponse(mimeType: "text/html", body: Data(html.utf8))
    }

    private static let style = """
        <style>
          :root { color-scheme: light dark; font: 15px/1.5 -apple-system, system-ui; }
          body { margin: 0; padding: 32px; }
          button { font: inherit; padding: 6px 14px; border-radius: 8px; border: 1px solid #8884; background: #8882; }
          pre { margin: 0; font: 13px/1.6 ui-monospace, Menlo, monospace; tab-size: 4; }
          body.wrap pre { white-space: pre-wrap; }
          .k { color: #ad3da4; } .s { color: #d12f1b; } .c { color: #707f8c; }
        </style>
        """

    private static let bridge = style + """
        <h2>Page</h2>
        <p>Each click calls Swift and awaits the new total.</p>
        <button onclick="add(1)">+1</button> <button onclick="add(10)">+10</button>
        <p id="total">Total from Swift: –</p>
        <p id="event"></p>
        <script>
          async function add(amount) {
            document.getElementById('total').textContent = 'Total from Swift: ' + await app.increment(amount);
          }
          app.on('shake', event => {
            document.getElementById('event').textContent = 'Event from Swift at ' + event.at;
          });
        </script>
        """

    private static let editor = style + """
        <pre><span class="c">// Rendered by Chromium, hosted in SwiftUI.</span>
        <span class="k">import</span> CefSwiftUI
        <span class="k">import</span> SwiftUI

        <span class="k">struct</span> Preview: View {
            <span class="k">var</span> body: <span class="k">some</span> View {
                CefWebView(url: URL(string: <span class="s">"https://example.com"</span>)!)
            }
        }</pre>
        """
}
