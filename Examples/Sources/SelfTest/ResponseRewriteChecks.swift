import AppKit
@_spi(Testing) import CefKit

/// `CefResourceRequestAction.rewriteResponse(_:)`: a request filter that
/// rewrites response bodies, against the local server.
extension SelfTest {
    /// What the rewriters saw of each response's headers, by path.
    @CefIOActor static var rewriteSeen: [String: (status: Int, mimeType: String?)] = [:]

    static func responseRewriteChecks() async {
        guard let server = try? await LocalServer.start() else {
            check("response rewriting: local server starts", false)
            return
        }
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        let profile = CefProfile.incognito()
        profile.requestFilter = CefRequestFilter(urlPatterns: ["*/policy/*", "*/large*", "*/status*"]) { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            switch (path, query) {
            case ("/policy/page", _):
                return .rewriteResponse(CefResponseRewriter { response in
                    rewriteSeen[path] = (response.statusCode, response.mimeType)
                    return { body in
                        Data(String(decoding: body, as: UTF8.self)
                            .replacingOccurrences(of: "<title>policy</title>", with: "<title>rewritten</title>").utf8)
                    }
                })
            case ("/large", "300000"):
                // Shorter than the Content-Length the server sent.
                return .rewriteResponse(CefResponseRewriter { _ in { body in Data("short \(body.count)".utf8) } })
            case ("/large", "3000000"):
                return .rewriteResponse(CefResponseRewriter(maximumLength: 1 << 20) { _ in { _ in Data("rewritten".utf8) } })
            case ("/large", "0"):
                return .rewriteResponse(CefResponseRewriter { _ in { _ in Data("from nothing".utf8) } })
            case ("/status", _):
                return .rewriteResponse(CefResponseRewriter { response in
                    rewriteSeen[path] = (response.statusCode, response.mimeType)
                    return nil
                })
            case ("/policy/allowed", _):
                // Longer than what was sent.
                return .rewriteResponse(CefResponseRewriter { _ in { body in body + Data(count: 200_000) } })
            default:
                return .allow
            }
        }
        var configuration = CefPage.Configuration()
        configuration.profile = profile
        let page = CefPage(url: URL(string: "\(base)/policy/page")!, configuration: configuration)
        let view = hostWindowed(page)
        defer { Task { await closeHosted(page, view) } }
        check("response rewriting: a page's HTML is rewritten before it is parsed",
              await loaded(page, title: "rewritten"), detail: page.title)
        let pageSeen = await Task { @CefIOActor in rewriteSeen["/policy/page"] }.value
        check("response rewriting: the rewriter sees the response's status and type",
              pageSeen?.status == 200 && pageSeen?.mimeType == "text/html",
              detail: "\(String(describing: pageSeen))")

        func fetch(_ path: String) async -> String {
            (try? await page.evaluateJavaScript("""
                fetch('\(path)').then(async r => { const b = await r.arrayBuffer();
                  return r.status + ' ' + b.byteLength + ' ' + new TextDecoder().decode(b.slice(0, 40)); }, e => 'failed ' + e)
                """, timeout: .seconds(20)).stringValue) ?? "no answer"
        }
        let shorter = await fetch("/large?300000")
        check("response rewriting: a body shorter than its Content-Length arrives whole",
              shorter == "200 12 short 300000", detail: shorter)
        let longer = await fetch("/policy/allowed")
        check("response rewriting: a body longer than the original arrives whole",
              longer.hasPrefix("200 200002 ok"), detail: String(longer.prefix(60)))
        let empty = await fetch("/large?0")
        check("response rewriting: an empty body can be replaced",
              empty == "200 12 from nothing", detail: empty)
        let tooLong = await fetch("/large?3000000")
        check("response rewriting: a body past maximumLength passes through unchanged",
              tooLong.hasPrefix("200 3000000 "), detail: String(tooLong.prefix(40)))
        let untouched = await fetch("/status?418")
        let statusSeen = await Task { @CefIOActor in rewriteSeen["/status"] }.value
        check("response rewriting: a rewriter that returns nil leaves the response alone",
              untouched == "418 6 teapot" && statusSeen?.status == 418, detail: "\(untouched) \(String(describing: statusSeen))")
    }
}
