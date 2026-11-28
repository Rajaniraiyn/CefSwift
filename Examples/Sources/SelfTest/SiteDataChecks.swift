import AppKit
@_spi(Testing) import CefKit

/// Clearing one site's data (`CefProfile.clearSiteData(for:types:)`) and
/// leaving the others'.
extension SelfTest {
    static func siteDataChecks() async {
        let hosts = ["a.sitedata.cefswift.test", "b.sitedata.cefswift.test"]
        for host in hosts {
            CefRuntime.shared.registerSchemeHandler(scheme: "https", domain: host, handler: SiteDataPage())
        }
        let profile = CefProfile.incognito()
        let pages = hosts.map { host in
            var configuration = CefPage.Configuration()
            configuration.profile = profile
            return CefPage(url: URL(string: "https://\(host)/")!, configuration: configuration)
        }
        let views = pages.map { hostWindowed($0) }
        defer {
            pages.forEach { $0.close(force: true) }
            views.forEach { $0.removeFromSuperview() }
        }
        for page in pages {
            guard await loaded(page, title: "site data") else {
                check("siteData: pages load", false, detail: page.title)
                return
            }
        }
        let (a, b) = (pages[0], pages[1])
        let store = """
            (async () => {
              localStorage.setItem('k', 'v');
              document.cookie = 'c=1; max-age=3600; secure';
              await new Promise((resolve, reject) => {
                const open = indexedDB.open('db', 1);
                open.onupgradeneeded = () => open.result.createObjectStore('s');
                open.onsuccess = () => { open.result.close(); resolve(); };
                open.onerror = () => reject(open.error);
              });
              await (await caches.open('cache')).put('/x', new Response('x'));
              return 1;
            })()
            """
        let read = """
            (async () => [localStorage.getItem('k') ?? '', document.cookie,
              (await indexedDB.databases()).map(d => d.name).join(), (await caches.keys()).join()].join('|'))()
            """
        let everything = "v|c=1|db|cache"
        await expect("siteData: each site stores cookies, local storage, IndexedDB and Cache Storage") {
            for page in pages { _ = try await page.evaluateJavaScript(store) }
            let stored = try await a.evaluateJavaScript(read).stringValue ?? ""
            return (stored == everything, stored)
        }
        await expect("siteData: clearing a site removes all of its data") {
            try await profile.clearSiteData(for: URL(string: "https://\(hosts[0])/some/path?query")!)
            a.reload()
            _ = await loaded(a, title: "site data")
            let left = try await a.evaluateJavaScript(read).stringValue ?? ""
            let cookies = try await profile.cookies(for: URL(string: "https://\(hosts[0])/")!)
            return (left == "|||" && cookies.isEmpty, "\(left), \(cookies.count) cookies")
        }
        await expect("siteData: other sites keep theirs") {
            let other = try await b.evaluateJavaScript(read).stringValue ?? ""
            return (other == everything, other)
        }
        await expect("siteData: only the types asked for") {
            try await profile.clearSiteData(for: URL(string: "https://\(hosts[1])")!, types: [.localStorage])
            let left = try await b.evaluateJavaScript(read).stringValue ?? ""
            return (left == "|c=1|db|cache", left)
        }
        await expect("siteData: a profile without a live page throws") {
            do {
                try await CefProfile.incognito().clearSiteData(for: URL(string: "https://\(hosts[0])")!)
                return (false, "no error")
            } catch let error as CefError {
                return (true, "\(error)")
            }
        }
    }
}

/// A page with an origin of its own for the site-data checks.
struct SiteDataPage: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        CefSchemeResponse(mimeType: "text/html", body: Data("<!doctype html><title>site data</title><p>site data".utf8))
    }
}
