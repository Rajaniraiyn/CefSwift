import CCef
import CefBase
import Foundation

extension CefBrowser {
    /// The pages a browser can go back and forward to, as
    /// `WKBackForwardList` lists them: a snapshot of Chromium's navigation
    /// entries (``CefBrowser/backForwardList``).
    public struct BackForwardList: Sendable, Equatable {
        /// One page of the list.
        public struct Item: Sendable, Equatable, Identifiable {
            /// The item's place in the list when it was read, from 0 (the
            /// oldest page).
            public var id: Int
            /// The page's address.
            public var url: URL?
            /// The address to show, which can differ from ``url`` for
            /// some internal pages, such as a page Chromium shows for an
            /// error.
            public var displayURL: URL?
            /// The address first asked for, before redirects.
            public var originalURL: URL?
            public var title: String
            /// The HTTP status of the page's response; 0 for a page not
            /// loaded over HTTP or not loaded yet.
            public var httpStatusCode: Int
            /// When the page finished loading; nil when it has not.
            public var completionDate: Date?
            /// How the page was reached.
            public var transition: CefNavigationTransition
            /// Whether the page was the result of a POST, which going back
            /// to it sends again.
            public var hasPostData: Bool

            /// Creates a value of your own, for previews and tests.
            public init(
                id: Int, url: URL?, displayURL: URL? = nil, originalURL: URL? = nil, title: String = "",
                httpStatusCode: Int = 0, completionDate: Date? = nil,
                transition: CefNavigationTransition = CefNavigationTransition(source: .link), hasPostData: Bool = false
            ) {
                self.id = id
                self.url = url
                self.displayURL = displayURL
                self.originalURL = originalURL
                self.title = title
                self.httpStatusCode = httpStatusCode
                self.completionDate = completionDate
                self.transition = transition
                self.hasPostData = hasPostData
            }
        }

        /// Every page, oldest first.
        public var items: [Item]
        /// The index of the current page in ``items``; nil for an empty
        /// list.
        public var currentIndex: Int?

        /// Creates a value of your own, for previews and tests.
        public init(items: [Item], currentIndex: Int?) {
            self.items = items
            self.currentIndex = currentIndex
        }

        /// The page shown now.
        public var currentItem: Item? { currentIndex.map { items[$0] } }
        /// The page ``CefBrowser/goBack()`` goes to.
        public var backItem: Item? { item(at: -1) }
        /// The page ``CefBrowser/goForward()`` goes to.
        public var forwardItem: Item? { item(at: 1) }
        /// The pages before the current one, the nearest last.
        public var backList: [Item] { currentIndex.map { Array(items[..<$0]) } ?? [] }
        /// The pages after the current one, the nearest first.
        public var forwardList: [Item] { currentIndex.map { Array(items[($0 + 1)...]) } ?? [] }

        /// The page `offset` steps from the current one: -1 is the back
        /// item, 1 the forward item.
        public func item(at offset: Int) -> Item? {
            guard let currentIndex else { return nil }
            let (index, overflow) = currentIndex.addingReportingOverflow(offset)
            return !overflow && items.indices.contains(index) ? items[index] : nil
        }
    }

    /// The back/forward list as Chromium has it now. Reading it in a
    /// SwiftUI view updates the view as the browser navigates.
    ///
    /// Empty while the browser has nothing in Chromium (before it is
    /// created, or while discarded by closing it).
    public var backForwardList: BackForwardList {
        // Observed, so a view showing the list follows navigations.
        _ = url
        _ = canGoBack
        _ = canGoForward
        let collector = NavigationEntryCollector()
        withHost { host in
            // The visitor is consumed; CEF visits before this returns.
            host.pointee.get_navigation_entries(host, collector.makeVisitor(), 0)
        }
        return BackForwardList(items: collector.items, currentIndex: collector.currentIndex)
    }

    /// Goes to `item` of ``backForwardList``, in one navigation however far
    /// it is: Chromium starts each step from the one still pending, so the
    /// pages in between are not loaded. Returns `false`, and does nothing,
    /// when the list has changed so that `item` is no longer at its place.
    ///
    /// ```swift
    /// if let first = browser.backForwardList.backList.first { browser.go(to: first) }
    /// ```
    @discardableResult
    public func go(to item: BackForwardList.Item) -> Bool {
        let list = backForwardList
        guard let current = list.currentIndex, list.items.indices.contains(item.id),
              list.items[item.id].url == item.url
        else { return false }
        let offset = item.id - current
        guard offset != 0 else { return true }
        guard let browser = raw?.pointer else { return false }
        for _ in 0..<abs(offset) {
            if offset < 0 { browser.pointee.go_back(browser) } else { browser.pointee.go_forward(browser) }
        }
        return true
    }
}

/// Collects navigation entries; CEF visits on the UI thread, before
/// `get_navigation_entries` returns.
private final class NavigationEntryCollector: @unchecked Sendable {
    var items: [CefBrowser.BackForwardList.Item] = []
    var currentIndex: Int?

    /// The returned +1 reference is consumed by `get_navigation_entries`.
    func makeVisitor() -> UnsafeMutablePointer<cef_navigation_entry_visitor_t> {
        let visitor = cefAllocate(cef_navigation_entry_visitor_t.self, owner: self)
        visitor.pointee.visit = { s, entry, current, index, _ in
            defer { cefRelease(entry) }
            guard let entry, let owner = cefOwner(NavigationEntryCollector.self, s) else { return 0 }
            guard entry.pointee.is_valid(entry) != 0 else { return 1 }
            if current != 0 { owner.currentIndex = owner.items.count }
            owner.items.append(CefBrowser.BackForwardList.Item(entry: entry, id: owner.items.count))
            _ = index
            return 1
        }
        return visitor
    }
}

extension CefBrowser.BackForwardList.Item {
    init(entry: UnsafeMutablePointer<cef_navigation_entry_t>, id: Int) {
        func url(_ string: cef_string_userfree_t?) -> URL? {
            CefStringUtil.takingUserFree(string).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        }
        let completion = entry.pointee.get_completion_time(entry)
        self.init(
            id: id,
            url: url(entry.pointee.get_url(entry)),
            displayURL: url(entry.pointee.get_display_url(entry)),
            originalURL: url(entry.pointee.get_original_url(entry)),
            title: CefStringUtil.takingUserFree(entry.pointee.get_title(entry)) ?? "",
            httpStatusCode: Int(entry.pointee.get_http_status_code(entry)),
            completionDate: completion.val == 0 ? nil : completion.date,
            transition: CefNavigationTransition(cefValue: entry.pointee.get_transition_type(entry).rawValue),
            hasPostData: entry.pointee.has_post_data(entry) != 0)
    }
}

extension CefNavigationTransition {
    init(cefValue value: UInt32) {
        let source: Source = switch value & TT_SOURCE_MASK.rawValue {
        case TT_LINK.rawValue: .link
        case TT_EXPLICIT.rawValue: .explicit
        case TT_AUTO_BOOKMARK.rawValue: .autoBookmark
        case TT_AUTO_SUBFRAME.rawValue: .autoSubframe
        case TT_MANUAL_SUBFRAME.rawValue: .manualSubframe
        case TT_GENERATED.rawValue: .generated
        case TT_AUTO_TOPLEVEL.rawValue: .autoToplevel
        case TT_FORM_SUBMIT.rawValue: .formSubmit
        case TT_RELOAD.rawValue: .reload
        case TT_KEYWORD.rawValue: .keyword
        case TT_KEYWORD_GENERATED.rawValue: .keywordGenerated
        default: .unknown
        }
        self.init(
            source: source,
            isBackForward: value & TT_FORWARD_BACK_FLAG.rawValue != 0,
            isRedirect: value & TT_IS_REDIRECT_MASK.rawValue != 0,
            isDirectLoad: value & TT_DIRECT_LOAD_FLAG.rawValue != 0,
            isFromAPI: value & TT_FROM_API_FLAG.rawValue != 0)
    }
}
