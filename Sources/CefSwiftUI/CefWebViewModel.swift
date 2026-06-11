import AppKit
import CefKit
import Observation

/// An observable view model driving a single ``CefWebView``.
///
/// `CefWebViewModel` is the SwiftUI-facing state container for one CEF browser. It acts as the
/// `CefBrowserDelegate` of its browser, mirroring navigation state (`title`, `isLoading`,
/// `estimatedProgress`, `canGoBack`, `canGoForward`, `faviconURL`) into `@Observable`
/// properties so SwiftUI views update automatically.
///
/// Setting ``url`` navigates the browser; the browser's own address changes are reflected back
/// into ``url`` without re-triggering navigation.
///
/// ```swift
/// @State private var model = CefWebViewModel(url: URL(string: "https://example.com")!)
///
/// var body: some View {
///     VStack {
///         Text(model.title)
///         CefWebView(model: model)
///     }
/// }
/// ```
@Observable @MainActor
public final class CefWebViewModel {

    // MARK: State

    /// The current URL. Assigning a new value navigates the browser.
    ///
    /// When the browser itself navigates (link click, redirect, …) this property is updated to
    /// the new address without issuing another load.
    public var url: URL? {
        didSet {
            // Feedback-loop guard: don't navigate when the change originated from the
            // browser's own address-change notification, and skip no-op assignments.
            guard !isApplyingBrowserURL, let url, url != oldValue else { return }
            browser?.load(url)
        }
    }

    /// The current page title.
    public private(set) var title: String = ""

    /// Whether the browser is currently loading.
    public private(set) var isLoading: Bool = false

    /// An estimate of the current load's progress, from 0.0 to 1.0.
    public private(set) var estimatedProgress: Double = 0

    /// Whether the browser can navigate back in its history.
    public private(set) var canGoBack: Bool = false

    /// Whether the browser can navigate forward in its history.
    public private(set) var canGoForward: Bool = false

    /// The URL of the page's favicon, if one has been reported.
    public private(set) var faviconURL: URL?

    /// The underlying CEF browser, available once the hosting view has created it.
    public private(set) var browser: CefBrowser?

    /// Options used when the browser is created. Changes after creation have no effect.
    public var options: CefBrowserOptions

    // MARK: Pluggable hooks (all optional)

    /// Called for every JavaScript console message emitted by the page.
    public var onConsoleMessage: ((String) -> Void)?

    /// Called when the page requests a popup (e.g. `window.open`). Return a
    /// `CefPopupDecision` (`.allow`, `.block`, or `.openInSameBrowser`).
    /// When `nil`, popups are allowed.
    public var onPopupRequest: ((URL?) -> CefPopupDecision)?

    /// Called when a download is about to begin; return a
    /// `CefDownloadDecision`. When `nil`, downloads are saved to
    /// `~/Downloads/<suggested name>`.
    public var onDownloadDecision: ((CefDownload, _ suggestedName: String) -> CefDownloadDecision)?

    /// Called whenever a download's progress or state changes (including the
    /// final completed/canceled update).
    public var onDownloadProgress: ((CefDownload) -> Void)?

    /// Set while mirroring a browser-reported address change into ``url``,
    /// so the `didSet` observer doesn't navigate again.
    @ObservationIgnored private var isApplyingBrowserURL = false

    // MARK: Lifecycle

    /// Creates a view model, optionally with an initial URL and browser options.
    /// - Parameters:
    ///   - url: The URL to load once a browser is created.
    ///   - options: Creation-time browser options (runtime style, background color).
    public init(url: URL? = nil, options: CefBrowserOptions = .init()) {
        self.url = url
        self.options = options
    }

    /// Adopts a freshly created browser. Called by the hosting view.
    func attach(_ browser: CefBrowser) {
        self.browser = browser
        browser.delegate = self
        // Seed mirrored state from the browser's current values.
        title = browser.title
        isLoading = browser.isLoading
        canGoBack = browser.canGoBack
        canGoForward = browser.canGoForward
        if let browserURL = browser.url {
            isApplyingBrowserURL = true
            url = browserURL
            isApplyingBrowserURL = false
        }
    }

    /// Disowns the current browser (closing is the hosting view's responsibility).
    func detach() {
        if browser?.delegate === self {
            browser?.delegate = nil
        }
        browser = nil
    }

    // MARK: Commands

    /// Navigates to `url` (equivalent to assigning ``url``).
    public func load(_ url: URL) {
        self.url = url
    }

    /// Navigates back in history.
    public func goBack() { browser?.goBack() }

    /// Navigates forward in history.
    public func goForward() { browser?.goForward() }

    /// Reloads the current page.
    public func reload() { browser?.reload() }

    /// Stops the current load.
    public func stopLoading() { browser?.stopLoading() }

    /// Executes JavaScript in the page's main frame.
    /// - Parameter script: The JavaScript source to evaluate.
    public func executeJavaScript(_ script: String) {
        browser?.executeJavaScript(script)
    }
}

// MARK: - CefBrowserDelegate

extension CefWebViewModel: CefBrowserDelegate {

    public func browser(_ b: CefBrowser, didChangeTitle title: String) {
        self.title = title
    }

    public func browser(_ b: CefBrowser, didChangeURL url: URL?) {
        isApplyingBrowserURL = true
        self.url = url
        isApplyingBrowserURL = false
    }

    public func browser(
        _ b: CefBrowser,
        didChangeLoading isLoading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        if !isLoading {
            estimatedProgress = 1
        }
    }

    public func browser(_ b: CefBrowser, didChangeProgress progress: Double) {
        estimatedProgress = progress
    }

    public func browser(_ b: CefBrowser, didChangeFavicon urls: [URL]) {
        faviconURL = urls.first
    }

    public func browser(_ b: CefBrowser, requestsPopupFor url: URL?) -> CefPopupDecision {
        onPopupRequest?(url) ?? .allow
    }

    public func browserDidClose(_ b: CefBrowser) {
        detach()
        isLoading = false
        canGoBack = false
        canGoForward = false
    }

    public func browser(
        _ b: CefBrowser,
        didReceiveConsoleMessage message: String,
        level: CefLogSeverity,
        source: String,
        line: Int
    ) {
        onConsoleMessage?(message)
    }

    public func browser(
        _ b: CefBrowser,
        decidePolicyForDownload download: CefDownload,
        suggestedName: String
    ) -> CefDownloadDecision {
        onDownloadDecision?(download, suggestedName) ?? .allow(destination: nil)
    }

    public func browser(_ b: CefBrowser, downloadDidProgress download: CefDownload) {
        onDownloadProgress?(download)
    }
}
