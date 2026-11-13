import CefSwiftUI
import SwiftUI

/// A custom scheme serves the app's own content: declare it in the runtime
/// configuration's `customSchemes` (the gallery declares `gallery`), then
/// register a `CefSchemeHandler` before a page loads from it.
/// `CefDirectorySchemeHandler` serves a folder of the app's resources, here
/// `Resources/Site`; this handler wraps it to log each request on the main
/// actor.
struct CustomSchemeDemo: Demo {
    let title = "Custom Scheme"
    let summary = "A page, its style sheet, image and data served from the app's resources at gallery://site/, with each request the handler answers."
    let symbol = "shippingbox"
    let category = DemoCategory.network

    func makeView() -> some View { CustomSchemeView() }
}

private struct CustomSchemeView: View {
    @State private var site = SiteHandler()
    @State private var browser: CefBrowser?

    var body: some View {
        HSplitView {
            if let browser {
                CefWebView(browser)
                    .frame(minWidth: 360)
                    .readyWhenLoaded(browser)
                    .onDisappear { browser.close(force: true) }
            }
            List(site.requests.reversed(), id: \.self) { line in
                Text(line).font(.callout.monospaced())
            }
            .frame(minWidth: 220, maxWidth: 320)
        }
        .onAppear {
            // Register the handler first, then load from the scheme.
            CefRuntime.shared.registerSchemeHandler(scheme: "gallery", domain: "site", handler: site)
            browser = CefBrowser(url: URL(string: "gallery://site/index.html")!)
        }
    }
}

/// Serves `Resources/Site` and keeps a log of what it served. Isolated to
/// the main actor, so it can update the view's state directly.
@MainActor
@Observable
private final class SiteHandler: CefSchemeHandler {
    private(set) var requests: [String] = []
    @ObservationIgnored private let files = CefDirectorySchemeHandler(
        directory: Bundle.module.url(forResource: "Site", withExtension: nil)!)

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        let response = await files.response(for: request)
        requests.append("\(response.status) \(request.url?.path() ?? "")")
        return response
    }
}
