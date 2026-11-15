import AppKit
import CefKit

// The back/forward list from Chromium's navigation entries, and going to
// an entry several steps away in one navigation.
extension SelfTest {
    @MainActor
    private final class LoadRecorder: CefPageDelegate {
        var finished: [URL?] = []
        func page(_ page: CefPage, didFinishLoadWithStatus httpStatus: Int) { finished.append(page.url) }
    }

    static func backForwardChecks() async {
        func pageURL(_ n: Int) -> URL { URL(string: "selftest://app/second.html?page=\(n)")! }
        let page = CefPage(url: pageURL(1))
        let recorder = LoadRecorder()
        page.delegate = recorder
        let view = hostWindowed(page)
        defer { view.removeFromSuperview() }
        var loadedAll = await loaded(page, title: "second")
        for n in 2...4 where loadedAll { loadedAll = await load(pageURL(n), in: page, title: "second") }
        guard loadedAll else {
            check("back/forward: pages load", false, detail: page.title)
            await closeHosted(page, view)
            return
        }

        let list = page.backForwardList
        check("back/forward: the list has every page, the current one last",
              list.items.map(\.url) == (1...4).map(pageURL) && list.currentIndex == 3
                  && list.backList.count == 3 && list.forwardList.isEmpty && list.backItem?.url == pageURL(3),
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
        check("back/forward: go(to:) accepts an item at its place", page.go(to: first))
        _ = await waitUntil { page.url == pageURL(1) && !page.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
        let after = page.backForwardList
        let loads = recorder.finished.dropFirst(loadsBefore)
        check("back/forward: go(to:) reaches an item three steps back, loading only it",
              page.url == pageURL(1) && Array(loads) == [pageURL(1)] && after.currentIndex == 0
                  && after.forwardList.map(\.url) == (2...4).map(pageURL),
              detail: "at \(page.url?.query ?? "-"), loads \(loads.map { $0?.query ?? "-" })")
        check("back/forward: going back is recorded as such",
              after.currentItem?.transition.isBackForward == true, detail: "\(String(describing: after.currentItem?.transition))")
        check("back/forward: a stale item is refused",
              !page.go(to: CefPage.BackForwardList.Item(id: 2, url: URL(string: "selftest://app/elsewhere"))))
        await closeHosted(page, view)
        check("back/forward: a closed browser's list is empty", page.backForwardList.items.isEmpty)
    }
}
