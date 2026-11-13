import CefKit
import Foundation
import os

/// A page the gallery serves itself, so that demos work offline: at
/// `gallery://pages/<path>` through a `CefSchemeHandler`, and at
/// `http://localhost:<port>/<path>` through ``LocalServer`` for demos that
/// need real HTTP (cookies, permissions, passkeys).
///
/// A demo declares its page next to its code, as a `static let`; the page
/// is served from the moment it is first used.
struct SamplePage: Sendable {
    let path: String

    init(_ path: String, mimeType: String = "text/html", content: String) {
        self.path = path
        SamplePages.store.withLock { $0[path] = (mimeType, Data(content.utf8)) }
    }

    /// An HTML page with the gallery's style sheet.
    init(_ path: String, title: String, body: String) {
        self.init(path, content: """
            <!doctype html><meta charset=utf-8><title>\(title)</title>
            <meta name=viewport content="width=device-width">
            <style>\(SamplePages.style)</style>
            \(body)
            """)
    }

    var url: URL { URL(string: "gallery://pages/\(path)")! }
    var localURL: URL { LocalServer.shared.url(path: path) }
}

/// Serves every ``SamplePage``.
struct SamplePages: CefSchemeHandler {
    static let store = OSAllocatedUnfairLock<[String: (mimeType: String, body: Data)]>(initialState: [:])

    static func page(at path: String) -> (mimeType: String, body: Data)? {
        store.withLock { $0[path] }
    }

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        let path = String(request.url?.path().dropFirst() ?? "")
        guard let page = Self.page(at: path) else { return .notFound() }
        return CefSchemeResponse(mimeType: page.mimeType, body: page.body)
    }

    static let style = """
        :root { color-scheme: light dark; font: 15px/1.55 -apple-system, system-ui; }
        body { margin: 0 auto; padding: 28px 36px; max-width: 760px; }
        h1 { font-size: 26px; margin: 0 0 12px; }
        button, input, select { font: inherit; }
        button { padding: 5px 14px; border-radius: 7px; border: 1px solid #8885; background: #8881; cursor: pointer; }
        button:hover { background: #8882; }
        input { padding: 5px 10px; border-radius: 7px; border: 1px solid #8885; background: transparent; }
        code, pre { font: 13px ui-monospace, monospace; }
        .muted { color: #888; }
        .card { padding: 14px 18px; border-radius: 12px; background: #8881; margin: 14px 0; }
        """
}

extension SamplePage {
    /// A few linked pages, for navigation and history.
    static let tour = (1...3).map { number in
        SamplePage("tour/\(number).html", title: "Tour, page \(number)", body: """
            <h1>Page \(number) of 3</h1>
            <p>Follow the links to build up history, then go back and forward.</p>
            <p class=card>\(tourText[number - 1])</p>
            <p>\((1...3).map { $0 == number ? "<b>\($0)</b>" : "<a href=\"\($0).html\">Page \($0)</a>" }.joined(separator: " · "))</p>
            """)
    }

    private static let tourText = [
        "CefSwift embeds Chromium in a macOS app through the Chromium Embedded Framework.",
        "Each CefBrowser is an observable model: its title, address and progress are properties a view reads.",
        "Pages like this one come from a CefSchemeHandler, so the gallery works offline.",
    ]

    /// A long article with headings, for find in page and PDF.
    static let article = SamplePage("article.html", title: "On Embedding a Browser", body: """
        <h1>On Embedding a Browser</h1>
        <p class=muted>A sample article served by the gallery.</p>
        \(articleSections.map { "<h2>\($0.0)</h2><p>\($0.1)</p><p>\($0.1)</p>" }.joined())
        """)

    private static let articleSections = [
        ("Why embed a browser",
         "An app embeds a browser to show web content it does not control, or content of its own written with web technology. The browser brings layout, scripting, media and accessibility, and the app decides how it is framed."),
        ("Processes",
         "Chromium runs pages in renderer processes of their own. A page that crashes takes down its renderer, not the app, and the app hears about it from its delegate."),
        ("Rendering",
         "A windowed browser draws into a view of Chromium's own. An offscreen browser hands each frame to the app, which can composite it with native content above and below."),
        ("Talking to the page",
         "Scripts can be evaluated in any frame, and a bridge exposes Swift functions to the page as promises. Both directions carry typed values."),
        ("Profiles",
         "A profile holds cookies, storage and cache. Browsers in the same profile share a session; an incognito profile keeps everything in memory."),
    ]
}
