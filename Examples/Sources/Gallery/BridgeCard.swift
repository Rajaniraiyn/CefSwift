import SwiftUI
import CefKit
import CefSwiftUI

// Swift ↔ JS bridge demo: a custom-scheme page (gallery://) whose JavaScript
// calls a Swift function via `window.cefSwift.invoke`, renders the reply in
// the page, and mirrors every call into a native SwiftUI log.

/// Native side of the bridge demo. `activate()` runs once after CEF init:
/// registers the gallery:// page handler and the `greet` bridge function.
@Observable
@MainActor
final class BridgeDemo {
    static let shared = BridgeDemo()

    /// Native log of bridge calls (newest last).
    private(set) var log: [String] = []

    private var isActivated = false

    struct GreetRequest: Codable, Sendable { let name: String; let count: Int }
    struct GreetResponse: Codable, Sendable {
        let message: String
        let respondedBy: String
        let timestamp: String
    }

    func activate() {
        guard !isActivated else { return }
        isActivated = true

        // Serve the demo page on the custom scheme declared in
        // GalleryApp.cefConfiguration.customSchemes.
        CefRuntime.shared.registerSchemeHandler(scheme: "gallery", handler: BridgeDemoPageHandler())

        // The Swift function the page calls. Runs with app privileges:
        // treat params as untrusted input (see docs/js-bridge.md).
        CefRuntime.shared.bridge.register("greet") { [weak self] (request: GreetRequest) -> GreetResponse in
            let name = String(request.name.prefix(64))  // validate/clamp input
            await MainActor.run {
                self?.append("JS → Swift: greet(name: \"\(name)\", count: \(request.count))")
            }
            return GreetResponse(
                message: "Hello \(name) — greeting #\(request.count) from Swift!",
                respondedBy: "CefBridge in process \(ProcessInfo.processInfo.processIdentifier)",
                timestamp: Date.now.formatted(date: .omitted, time: .standard)
            )
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 100 { log.removeFirst() }
    }
}

/// Serves the demo page at gallery://app/. The page embeds
/// `CefBridge.javascriptShim` directly (the production-recommended pattern —
/// no reliance on late auto-injection), auto-invokes `greet` once on load so
/// the round-trip is visible without interaction, and has a button for more.
private struct BridgeDemoPageHandler: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        let html = """
            <!DOCTYPE html>
            <html><head><title>Swift ↔ JS Bridge</title>
            <script>\(CefBridge.javascriptShim)</script>
            <style>
              body { font: 14px -apple-system, sans-serif; margin: 20px; color: #1d1d1f; }
              button { font-size: 15px; padding: 8px 18px; border-radius: 8px;
                       border: none; background: #0071e3; color: white; cursor: pointer; }
              #reply { margin-top: 14px; padding: 10px; background: #f5f5f7;
                       border-radius: 8px; min-height: 3em; white-space: pre-wrap; }
              .meta { color: #6e6e73; font-size: 12px; }
            </style></head>
            <body>
              <button onclick="greet()">Call Swift from JS</button>
              <div id="reply">waiting for first round-trip…</div>
              <script>
                let count = 0;
                async function greet() {
                  count += 1;
                  try {
                    const reply = await window.cefSwift.invoke('greet', { name: 'Gallery', count: count });
                    document.getElementById('reply').innerHTML =
                      '<b>' + reply.message + '</b><br>' +
                      '<span class="meta">' + reply.respondedBy + ' at ' + reply.timestamp + '</span>';
                  } catch (error) {
                    document.getElementById('reply').textContent = 'bridge error: ' + error.message;
                  }
                }
                // Auto-invoke once so the round-trip shows without interaction.
                greet();
              </script>
            </body></html>
            """
        return CefSchemeResponse(status: 200, mimeType: "text/html", body: Data(html.utf8))
    }
}

/// The Gallery card: the gallery:// page up top, the native Swift log below.
struct SwiftJSBridgeCard: View {
    @State private var model: CefWebViewModel = {
        var options = CefBrowserOptions()
        options.runtimeStyle = .alloy
        return CefWebViewModel(url: URL(string: "gallery://app/")!, options: options)
    }()
    private let demo = BridgeDemo.shared

    var body: some View {
        GalleryCard(
            title: "Swift ↔ JS Bridge", symbol: "arrow.left.arrow.right",
            caption: "runtime.bridge.register(\"greet\")"
        ) {
            VStack(spacing: 0) {
                CefWebView(model: model)
                    .frame(height: 170)
                Divider()
                List(Array(demo.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .frame(height: 100)
                .overlay {
                    if demo.log.isEmpty {
                        Text("native log: Swift-side bridge calls appear here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
