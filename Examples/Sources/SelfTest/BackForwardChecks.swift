import AppKit
import CefKit

// The back/forward list from Chromium's navigation entries, and going to
// an entry several steps away in one navigation.
extension SelfTest {
    @MainActor
    private final class LoadRecorder: CefBrowserDelegate {
        var finished: [URL?] = []
        func browser(_ browser: CefBrowser, didFinishLoadWithStatus httpStatus: Int) { finished.append(browser.url) }
    }

    static func backForwardChecks() async {
        func page(_ n: Int) -> URL { URL(string: "selftest://app/second.html?page=\(n)")! }
        let browser = CefBrowser(url: page(1))
        let recorder = LoadRecorder()
        browser.delegate = recorder
        let view = hostWindowed(browser)
        defer { view.removeFromSuperview() }
        var loadedAll = await loaded(browser, title: "second")
        for n in 2...4 where loadedAll { loadedAll = await load(page(n), in: browser, title: "second") }
        guard loadedAll else {
            check("back/forward: pages load", false, detail: browser.title)
            await closeHosted(browser, view)
            return
        }

        let list = browser.backForwardList
        check("back/forward: the list has every page, the current one last",
              list.items.map(\.url) == (1...4).map(page) && list.currentIndex == 3
                  && list.backList.count == 3 && list.forwardList.isEmpty && list.backItem?.url == page(3),
              detail: "\(list.items.map { $0.url?.query ?? "-" }), current \(list.currentIndex.map(String.init) ?? "-")")
        let current = list.currentItem
        check("back/forward: an item has its title, status, completion time and transition",
              current?.title == "second" && current?.completionDate != nil
                  && current?.httpStatusCode == 200 && current?.transition.source == .explicit && current?.transition.isDirectLoad == true
                  && current?.hasPostData == false,
              detail: "\(String(describing: current))")

        // Three steps back in one navigation: the pages between do not load.
        let loadsBefore = recorder.finished.count
        guard let first = list.backList.first else { return }
        check("back/forward: go(to:) accepts an item at its place", browser.go(to: first))
        _ = await waitUntil { browser.url == page(1) && !browser.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
        let after = browser.backForwardList
        let loads = recorder.finished.dropFirst(loadsBefore)
        check("back/forward: go(to:) reaches an item three steps back, loading only it",
              browser.url == page(1) && Array(loads) == [page(1)] && after.currentIndex == 0
                  && after.forwardList.map(\.url) == (2...4).map(page),
              detail: "at \(browser.url?.query ?? "-"), loads \(loads.map { $0?.query ?? "-" })")
        check("back/forward: going back is recorded as such",
              after.currentItem?.transition.isBackForward == true, detail: "\(String(describing: after.currentItem?.transition))")
        check("back/forward: a stale item is refused",
              !browser.go(to: CefBrowser.BackForwardList.Item(id: 2, url: URL(string: "selftest://app/elsewhere"))))
        await closeHosted(browser, view)
        check("back/forward: a closed browser's list is empty", browser.backForwardList.items.isEmpty)
    }
}
