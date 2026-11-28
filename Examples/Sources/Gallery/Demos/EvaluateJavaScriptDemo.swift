import CefSwiftUI
import SwiftUI

/// `evaluateJavaScript(_:)` runs a script in the page's main frame, awaits
/// a promise it returns, and hands back the value as `CefJSON`; the `as:`
/// form decodes it into a `Decodable` type. A script that may never settle
/// takes a `timeout`. Exceptions arrive as `CefJavaScriptError`.
struct EvaluateJavaScriptDemo: Demo {
    let title = "Evaluate JavaScript"
    let summary = "Scripts run in the page from Swift: plain values, a promise, a result decoded into a Swift struct, an exception and a timeout."
    let symbol = "curlybraces"
    let category = DemoCategory.javaScript

    func makeView() -> some View { EvaluateJavaScriptView() }
}

private struct Viewport: Decodable {
    var width: Int
    var height: Int
    var scale: Double
}

private struct EvaluateJavaScriptView: View {
    @ViewState private var page = CefPage(url: SamplePage.article.url)
    @ViewState private var output = "Run a script."

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Title") { run { try await page.evaluateJavaScript("document.title").stringValue ?? "" } }
                Button("Count Headings") {
                    run { "\(try await page.evaluateJavaScript("document.querySelectorAll('h2').length").intValue ?? 0)" }
                }
                Button("Await a Promise") {
                    run { try await page.evaluateJavaScript("new Promise(r => setTimeout(() => r('resolved after 0.5 s'), 500))").stringValue ?? "" }
                }
                Button("Decode a Struct") {
                    run {
                        let viewport = try await page.evaluateJavaScript(
                            "({ width: innerWidth, height: innerHeight, scale: devicePixelRatio })", as: Viewport.self)
                        return "\(viewport.width) × \(viewport.height) points at \(viewport.scale)×"
                    }
                }
                Button("Throw") { run { "\(try await page.evaluateJavaScript("null.property"))" } }
                Button("Time Out") {
                    run { "\(try await page.evaluateJavaScript("new Promise(() => {})", timeout: .seconds(1)))" }
                }
            }
            .padding(10)
            Text(output)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .textSelection(.enabled)
            Divider()
            CefWebView(page)
        }
        .reportReady {
            try await page.waitUntilLoaded(timeout: .seconds(30))
            output = try await page.evaluateJavaScript("'Ready: ' + document.title").stringValue ?? ""
        }
        .onDisappear { page.close(force: true) }
    }

    private func run(_ script: @escaping () async throws -> String) {
        Task {
            do {
                output = "→ " + (try await script())
            } catch {
                output = "✕ \(error)"
            }
        }
    }
}
