import AppKit
import CefKit
import SwiftUI

/// A view that displays a ``CefBrowser``.
///
/// ```swift
/// // Self-contained: the view owns its browser.
/// CefWebView(url: URL(string: "https://example.com")!)
///
/// // Model-driven: keep the browser, bind UI to its state.
/// @State private var browser = CefBrowser(url: home)
///
/// CefWebView(browser)
///     .navigationTitle(browser.title)
/// ```
///
/// The browser's ``CefBrowserOptions/rendering`` picks how it draws:
/// `.windowed` (the default) embeds Chromium's own native view; `.offscreen`
/// composites the page in a layer so SwiftUI content can overlap it.
///
/// A view created with ``init(_:)`` never closes the browser you gave it —
/// it can leave the hierarchy and come back, or move to another view. Call
/// ``CefBrowser/close(force:)`` when you are done with it. A view created
/// with ``init(url:options:)`` closes its browser when it goes away.
public struct CefWebView: View {
    private let source: Source
    /// A swipe indicator of the app's own, set by
    /// ``navigationGestureIndicator(_:)``.
    var gestureIndicator: ((Double) -> AnyView)?

    private enum Source {
        case browser(CefBrowser)
        case url(URL, CefBrowserOptions)
    }

    /// Shows `browser`.
    public init(_ browser: CefBrowser) {
        source = .browser(browser)
    }

    /// Shows `url` in a browser owned by the view.
    public init(url: URL, options: CefBrowserOptions = .init()) {
        source = .url(url, options)
    }

    public var body: some View {
        switch source {
        case .browser(let browser):
            Host(browser: browser, ownsBrowser: false, gestureIndicator: gestureIndicator)
        case .url(let url, let options):
            OwnedHost(url: url, options: options, gestureIndicator: gestureIndicator)
        }
    }

    /// Keeps the view-owned browser alive across view updates.
    private struct OwnedHost: View {
        let url: URL
        let gestureIndicator: ((Double) -> AnyView)?
        // SwiftUI keeps the first browser and discards the ones later
        // initializers make; a browser does nothing in Chromium until hosted.
        @State private var browser: CefBrowser

        init(url: URL, options: CefBrowserOptions, gestureIndicator: ((Double) -> AnyView)?) {
            self.url = url
            self.gestureIndicator = gestureIndicator
            _browser = State(initialValue: CefBrowser(url: url, options: options))
        }

        var body: some View {
            Host(browser: browser, ownsBrowser: true, gestureIndicator: gestureIndicator)
                .onChange(of: url) { _, newURL in browser.load(newURL) }
        }
    }

    private struct Host: View {
        let browser: CefBrowser
        let ownsBrowser: Bool
        let gestureIndicator: ((Double) -> AnyView)?

        var body: some View {
            let showsBuiltIn = gestureIndicator == nil
            Group {
                switch browser.options.rendering {
                case .windowed:
                    WindowedRepresentable(browser: browser, ownsBrowser: ownsBrowser, showsBuiltInIndicator: showsBuiltIn)
                case .offscreen:
                    OffscreenRepresentable(browser: browser, ownsBrowser: ownsBrowser, showsBuiltInIndicator: showsBuiltIn)
                }
            }
            .overlay {
                if let gestureIndicator, browser.options.allowsBackForwardNavigationGestures {
                    GestureProgressReader(browser: browser, content: gestureIndicator)
                }
            }
        }
    }
}

private struct WindowedRepresentable: NSViewRepresentable {
    let browser: CefBrowser
    let ownsBrowser: Bool
    let showsBuiltInIndicator: Bool

    func makeNSView(context: Context) -> CefWindowedBrowserView {
        let view = CefWindowedBrowserView()
        view.closesBrowserOnTeardown = ownsBrowser
        view.showsBuiltInGestureIndicator = showsBuiltInIndicator
        view.browser = browser
        return view
    }

    func updateNSView(_ view: CefWindowedBrowserView, context: Context) {
        view.showsBuiltInGestureIndicator = showsBuiltInIndicator
        view.browser = browser
    }

    static func dismantleNSView(_ view: CefWindowedBrowserView, coordinator: ()) {
        view.tearDown()
    }
}

private struct OffscreenRepresentable: NSViewRepresentable {
    let browser: CefBrowser
    let ownsBrowser: Bool
    let showsBuiltInIndicator: Bool

    func makeNSView(context: Context) -> CefOffscreenBrowserView {
        let view = CefOffscreenBrowserView()
        view.closesBrowserOnTeardown = ownsBrowser
        view.showsBuiltInGestureIndicator = showsBuiltInIndicator
        view.browser = browser
        return view
    }

    func updateNSView(_ view: CefOffscreenBrowserView, context: Context) {
        view.showsBuiltInGestureIndicator = showsBuiltInIndicator
        view.browser = browser
    }

    static func dismantleNSView(_ view: CefOffscreenBrowserView, coordinator: ()) {
        view.tearDown()
    }
}

// MARK: - Windowed host view

/// An `NSView` showing a windowed browser: Chromium's own native view is
/// added as a subview and kept sized to fill it. Chromium handles input,
/// IME and accessibility itself.
///
/// `CefWebView` uses this for `.windowed` browsers; use it directly in
/// AppKit by assigning ``browser``.
@MainActor
public final class CefWindowedBrowserView: NSView {

    /// The browser shown in this view. Assigning a browser that is already
    /// live moves its native view here.
    public var browser: CefBrowser? {
        didSet {
            guard browser !== oldValue else { return }
            if let previous = oldValue?.nativeView, previous.superview === self {
                previous.removeFromSuperview()
            }
            hostBrowserIfPossible()
            gestureIndicator = updatedGestureIndicator(gestureIndicator, browser: browser, isAllowed: showsBuiltInGestureIndicator)
            updateSwipeMonitor()
        }
    }

    /// Whether the view draws the built-in swipe indicator that
    /// ``CefBrowserOptions/navigationGestureIndicator`` chooses. `CefWebView`
    /// turns it off for an indicator of the app's own.
    public var showsBuiltInGestureIndicator = true {
        didSet {
            gestureIndicator = updatedGestureIndicator(gestureIndicator, browser: browser, isAllowed: showsBuiltInGestureIndicator)
        }
    }

    private var gestureIndicator: CefNavigationGestureIndicatorView?
    private var swipeMonitor: Any?

    /// Whether dismantling the view closes its browser. `CefWebView(url:)`
    /// sets this for the browser it owns.
    var closesBrowserOnTeardown = false
    private var isTornDown = false

    public init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hostBrowserIfPossible()
        updateSwipeMonitor()
    }

    /// Keeps the indicator above Chromium's view, which is added later.
    public override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let gestureIndicator, subview !== gestureIndicator {
            addSubview(gestureIndicator, positioned: .above, relativeTo: nil)
        }
    }

    /// Chromium's view takes scroll events directly, so swipes are claimed
    /// before it sees them, while the view is in a window and the browser
    /// allows them.
    private func updateSwipeMonitor() {
        let wantsMonitor = !isTornDown && window != nil
            && browser?.options.allowsBackForwardNavigationGestures == true
        guard wantsMonitor != (swipeMonitor != nil) else { return }
        if let swipeMonitor {
            NSEvent.removeMonitor(swipeMonitor)
            self.swipeMonitor = nil
            return
        }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let claimed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let browser = self.browser, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return false }
                if event.type == .swipe {
                    return browser.handleNavigationSwipe(event)
                }
                return browser.beginHistorySwipeIfNeeded(with: event)
            }
            return claimed ? nil : event
        }
    }

    /// A discarded browser comes back when its view is shown again.
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        hostBrowserIfPossible()
    }

    /// Chromium can only create a windowed browser inside a window, so
    /// hosting waits until the view is in one.
    private func hostBrowserIfPossible() {
        guard !isTornDown, window != nil, let browser else { return }
        browser.host(windowedIn: self)
    }

    // MARK: Focus

    /// The view stands in the window's key-view loop for its page, so Tab
    /// and Shift-Tab from the app's controls reach it.
    public override var acceptsFirstResponder: Bool {
        browser?.state == .live && browser?.nativeView?.superview === self
    }

    /// Selected through the key-view loop, it hands focus to the page and
    /// focuses the page's first element (Tab) or last (Shift-Tab).
    public override func becomeFirstResponder() -> Bool {
        guard let browser, super.becomeFirstResponder() else { return false }
        let direction = window?.keyViewSelectionDirection ?? .directSelection
        // Once AppKit has finished selecting this view.
        DispatchQueue.main.async { browser.hostViewDidBecomeKey(selecting: direction) }
        return true
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        updateSwipeMonitor()
        if closesBrowserOnTeardown {
            browser?.close(force: true)
        }
        browser = nil
    }
}
