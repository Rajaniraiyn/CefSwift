import Foundation

/// A hidden Chrome-style browser parked on one of Chromium's own pages
/// (`chrome://bookmarks`, `chrome://history`, …) and driven as a data API
/// through the DevTools Protocol.
///
/// Chromium grants those pages bindings to its internal services — the
/// extension-style `chrome.bookmarks` API, or Mojo page handlers — that CEF
/// does not expose. Each call evaluates a function against a service object
/// that `setup` builds once per document, so a reloaded or recreated page
/// rebuilds it on demand.
///
/// The browser is created on first use and reused. A call that does not
/// finish in time, or a renderer that dies (Chromium kills a page that sends
/// a malformed Mojo message), discards the browser; the next call starts a
/// fresh one. Service browsers are listed in neither
/// ``CefRuntime/browsers`` nor ``CefBrowserWindow/all``, and are closed when
/// the app quits.
///
/// Service pages are loaded with the ``addressMarker`` fragment. Chromium
/// saves every Chrome-style window in its session, service windows
/// included, and reopens them after a crash; the marker lets
/// ``CefRuntime`` recognize those and close them instead of showing them.
@MainActor
final class CefInternalPageService {
    /// The fragment that marks a service page's address.
    nonisolated static let addressMarker = "cefswift-service"

    /// Whether `url` is a service page's address — one Chromium reopened
    /// from a previous session, when it does not belong to a live service.
    nonisolated static func isServicePage(_ url: URL) -> Bool {
        url.scheme == "chrome" && url.fragment == addressMarker
    }

    /// The profile owns this service, and its browser keeps it alive.
    unowned let profile: CefProfile
    /// The page's address, e.g. `chrome://history/`.
    let page: String
    /// A JavaScript expression evaluating to an async function that returns
    /// the service object handed to each call.
    let setup: String
    /// Name of a DevTools binding the page may call with a string payload,
    /// delivered to ``onNotification``.
    let notificationBinding: String?
    var onNotification: ((String) -> Void)?

    private var window: CefBrowserWindow?
    /// Discarded windows, kept until Chromium has finished closing them.
    private var retiredWindows: [CefBrowserWindow] = []
    private var browser: CefBrowser?
    private var starting: Task<CefBrowser, Error>?
    private var notifications: Task<Void, Never>?
    private let delegate = ServiceBrowserDelegate()

    init(profile: CefProfile, page: String, setup: String, notificationBinding: String? = nil) {
        self.profile = profile
        self.page = page
        self.setup = setup
        self.notificationBinding = notificationBinding
        delegate.onTerminated = { [weak self] browser in self?.discard(browser) }
    }

    /// Evaluates `function` — a JavaScript expression of the form
    /// `async (service, args) => value` — with `arguments` and returns its
    /// JSON result.
    func call(_ function: String, _ arguments: CefJSON = [:], timeout: Duration = .seconds(15)) async throws -> CefJSON {
        let browser = try await liveBrowser()
        let script = script(function, arguments)
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.discard(browser)
        }
        defer { watchdog.cancel() }
        do {
            return try await browser.evaluateJavaScript(script)
        } catch let error as CefJavaScriptError {
            throw CefError.operationFailed("\(page): \(error.message)")
        } catch CefError.browserClosed {
            throw CefError.operationFailed("\(page) stopped responding")
        }
    }

    /// Starts the service browser if it is not running yet.
    func start() async throws {
        _ = try await liveBrowser()
    }

    private func script(_ function: String, _ arguments: CefJSON) -> String {
        """
        (async () => {
          const service = await (window.__cefswiftService ??= (\(setup))().catch(error => {
            window.__cefswiftService = undefined;
            throw error;
          }));
          return await (\(function))(service, \(arguments.text));
        })()
        """
    }

    // MARK: Lifetime

    private func liveBrowser() async throws -> CefBrowser {
        if let starting { return try await starting.value }
        if let browser, browser.state == .live { return browser }
        guard CefRuntime.shared.isInitialized, !CefRuntime.shared.isTerminating else {
            throw CefError.notInitialized
        }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func launch() async throws -> CefBrowser {
        var options = CefBrowserOptions()
        options.profile = profile
        let browser = CefBrowser(url: URL(string: "\(page)#\(Self.addressMarker)"), options: options, delegate: delegate)
        CefRuntime.shared.registerServiceBrowser(browser)
        let window = CefBrowserWindow(browser: browser)
        window.isService = true
        self.browser = browser
        self.window = window

        try await browser.ready()
        if let notificationBinding {
            try await listen(to: browser, binding: notificationBinding)
        }
        // Wait for the page itself, not the initial navigation state.
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let loaded = try? await browser.evaluateJavaScript(
                "document.readyState === 'complete' && location.href.startsWith(\(CefJSON.string(page).text))")
            if loaded?.boolValue == true {
                // Some pages rewrite their address as they start (the
                // history page drops the fragment); mark it again.
                _ = try? await browser.evaluateJavaScript(
                    """
                    location.hash === '#\(Self.addressMarker)'
                      || history.replaceState(history.state, '', location.pathname + location.search + '#\(Self.addressMarker)')
                    """)
                // Set the service up now, so page-side listeners run
                // before the first call.
                _ = try? await browser.evaluateJavaScript(script("async () => true", [:]))
                return browser
            }
            guard browser.state == .live else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        discard(browser)
        throw CefError.operationFailed("\(page) did not load")
    }

    /// Installs `binding` as a page global; the DevTools Protocol reports
    /// its calls once the Runtime domain is enabled.
    private func listen(to browser: CefBrowser, binding: String) async throws {
        let events = browser.devTools.events("Runtime.bindingCalled")
        try await browser.devTools.send("Runtime.enable")
        try await browser.devTools.send("Runtime.addBinding", ["name": .string(binding)])
        notifications?.cancel()
        notifications = Task { [weak self] in
            for await event in events where event["name"].stringValue == binding {
                self?.onNotification?(event["payload"].stringValue ?? "")
            }
        }
    }

    /// Closes `browser` if it is still this service's browser; the next call
    /// creates a new one.
    private func discard(_ browser: CefBrowser) {
        guard browser === self.browser else { return }
        self.browser = nil
        retiredWindows.removeAll(where: \.isClosed)
        if let window { retiredWindows.append(window) }
        window = nil
        notifications?.cancel()
        notifications = nil
        browser.close(force: true)
    }
}

/// Watches a service browser for a dead renderer, whose pending evaluations
/// would otherwise never finish.
private final class ServiceBrowserDelegate: CefBrowserDelegate {
    var onTerminated: ((CefBrowser) -> Void)?

    func browser(_ browser: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason) {
        onTerminated?(browser)
    }
}
