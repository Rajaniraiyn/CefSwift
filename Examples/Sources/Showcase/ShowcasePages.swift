import CefSwiftUI
import Foundation

/// The app's own pages, served from `showcase://app/…`. A real app would
/// point `CefDirectorySchemeHandler` at a folder of bundled web resources.
struct ShowcasePages: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        switch request.url?.path {
        case "/bridge.html": page(Self.bridge)
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
}
