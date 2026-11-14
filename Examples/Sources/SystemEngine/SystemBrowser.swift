import AppKit
import CefKit
import CryptoKit
import Foundation
import Observation
import WebKit

/// A page shown by the system's web engine — WebKit, as in Safari — rather
/// than by Chromium. The Browser example uses it for streaming services;
/// it is example code built on `WKWebView` and CefKit's public API, not
/// part of the library.
///
/// Chromium in CefSwift plays protected media with Widevine, which
/// streaming services such as Netflix refuse without Verified Media Path
/// host signing, and Chromium has no FairPlay. WebKit on macOS has
/// FairPlay Streaming through Encrypted Media Extensions, needs no
/// entitlement or licence, and identifies as Safari, so services that
/// look for Safari serve it their Safari player. Use a system browser for
/// such sites and Chromium (`CefBrowser`) for everything else:
///
/// ```swift
/// func browser(_ browser: CefBrowser, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision {
///     guard navigation.isMainFrame, let url = navigation.url, SystemBrowser.prefersSystemEngine(for: url)
///     else { return .allow }
///     openSystemTab(SystemBrowser(url: url, configuration: .init(profile: browser.configuration.profile)))
///     return .cancel
/// }
/// ```
///
/// It has the parts of `CefBrowser`'s surface WebKit offers: navigation
/// and its observable state, JavaScript, user scripts, find, zoom and
/// snapshots. Show it with ``SystemWebView`` or by adding ``nativeView``
/// to a view hierarchy.
@MainActor
@Observable
public final class SystemBrowser {
    /// How a system browser is set up. Fixed when it is created.
    public struct Configuration {
        /// Whose website data (cookies, storage, cache) the page uses. Each
        /// `CefProfile` has a WebKit data store of its own, separate from
        /// Chromium's: the default profile uses the app's default store, a
        /// persistent profile a persistent store derived from its
        /// identifier, and an incognito profile an in-memory store
        /// discarded with it. `nil` is the default profile.
        public var profile: CefProfile?
        /// Whether the User-Agent ends `Version/<Safari's version>
        /// Safari/605.1.15`, as Safari's does, so sites serve their Safari
        /// pages and players. The engine is the one Safari uses. Off leaves
        /// WebKit's default, which names no browser.
        public var identifiesAsSafari = true
        /// Scripts added to every page, with their URL pattern, injection
        /// time and frames honored.
        public var userScripts: [CefUserScript] = []
        /// Two-finger swipes go back and forward.
        public var allowsBackForwardNavigationGestures = true

        public init(profile: CefProfile? = nil) {
            self.profile = profile
        }
    }

    /// The page's address.
    public private(set) var url: URL?
    public private(set) var title = ""
    public private(set) var isLoading = false
    /// Load progress, 0–1.
    public private(set) var estimatedProgress = 0.0
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    /// Whether every resource on the page arrived over a secure connection.
    public private(set) var hasOnlySecureContent = false

    /// The settings the browser was made with.
    @ObservationIgnored public let configuration: Configuration

    /// A main-frame navigation awaiting ``decidePolicy``.
    public struct Navigation {
        public var url: URL?
        /// Whether the user followed a link or submitted a form.
        public var hasUserGesture: Bool
    }

    /// Decides each main-frame navigation; `nil` allows all. Return
    /// `.cancel` to send a URL elsewhere, such as back to a Chromium
    /// browser when the user leaves a streaming site.
    @ObservationIgnored public var decidePolicy: ((SystemBrowser, Navigation) -> CefNavigationDecision)?

    /// Called when the page opens a new window (`target="_blank"`,
    /// `window.open`). `nil` loads the URL in this browser.
    @ObservationIgnored public var onOpenWindow: ((SystemBrowser, URL) -> Void)?

    /// The `WKWebView` showing the page.
    @ObservationIgnored public let nativeView: WKWebView

    @ObservationIgnored private let coordinator = Coordinator()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    public init(url: URL? = nil, configuration: Configuration = .init()) {
        self.configuration = configuration
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.websiteDataStore = Self.dataStore(for: configuration.profile ?? .default)
        webViewConfiguration.preferences.isElementFullscreenEnabled = true
        webViewConfiguration.mediaTypesRequiringUserActionForPlayback = []
        webViewConfiguration.allowsAirPlayForMediaPlayback = true
        if configuration.identifiesAsSafari {
            webViewConfiguration.applicationNameForUserAgent = Self.safariApplicationName
        }
        for script in configuration.userScripts {
            webViewConfiguration.userContentController.addUserScript(Self.webKitScript(for: script))
        }
        nativeView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        nativeView.allowsBackForwardNavigationGestures = configuration.allowsBackForwardNavigationGestures
        nativeView.allowsMagnification = true
        coordinator.browser = self
        nativeView.navigationDelegate = coordinator
        nativeView.uiDelegate = coordinator
        observe()
        if let url { load(url) }
    }

    // MARK: Navigation

    public func load(_ url: URL) {
        nativeView.load(URLRequest(url: url))
    }

    /// Shows `html` as if it had been loaded from `baseURL`.
    public func loadHTML(_ html: String, baseURL: URL?) {
        nativeView.loadHTMLString(html, baseURL: baseURL)
    }

    public func goBack() { nativeView.goBack() }
    public func goForward() { nativeView.goForward() }
    public func stopLoading() { nativeView.stopLoading() }

    public func reload(ignoringCache: Bool = false) {
        if ignoringCache { nativeView.reloadFromOrigin() } else { nativeView.reload() }
    }

    // MARK: JavaScript

    /// Evaluates `script` in the page and returns its value as JSON,
    /// awaiting it if it is a promise. Throws ``JavaScriptError`` when
    /// the script throws.
    ///
    /// As `CefBrowser.evaluateJavaScript` does, this runs
    /// `script` as a classic script: statements, declarations and `throw`
    /// work, and the value is that of the last statement. Its top-level
    /// `let`, `const` and `class` declarations stay local to the call. On a
    /// page whose Content Security Policy forbids `eval`, the script runs
    /// without awaiting a promise it returns.
    @discardableResult
    public func evaluateJavaScript(_ script: String) async throws -> CefJSON {
        // An indirect eval runs the source as a global classic script and
        // yields its completion value; callAsyncJavaScript awaits it.
        let body = "return await (0, eval)(source)"
        do {
            return CefJSON(foundationValue: try await nativeView.callAsyncJavaScript(
                body, arguments: ["source": script], contentWorld: .page))
        } catch let error as NSError where Self.isEvalBlocked(error) {
            // CSP: evaluateJavaScript is exempt, and runs a classic script.
            do {
                return CefJSON(foundationValue: try await nativeView.evaluateJavaScript(script, contentWorld: .page))
            } catch let error as NSError {
                throw Self.javaScriptError(error)
            }
        } catch let error as NSError {
            throw Self.javaScriptError(error)
        }
    }

    /// Whether `error` is the page's Content Security Policy refusing
    /// `eval`, which leaves `script` unrun.
    private static func isEvalBlocked(_ error: NSError) -> Bool {
        let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
        return message.hasPrefix("EvalError") && message.contains("unsafe-eval")
    }

    /// A JavaScript exception thrown by code passed to
    /// ``evaluateJavaScript(_:)``.
    public struct JavaScriptError: Error, CustomStringConvertible {
        public var message: String
        public var line: Int
        public var column: Int

        public var description: String { message }
    }

    private static func javaScriptError(_ error: NSError) -> JavaScriptError {
        let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
        let line = error.userInfo["WKJavaScriptExceptionLineNumber"] as? Int ?? 0
        let column = error.userInfo["WKJavaScriptExceptionColumnNumber"] as? Int ?? 0
        return JavaScriptError(message: message, line: line, column: column)
    }

    /// Evaluates `script` and decodes its value as `T`.
    public func evaluateJavaScript<T: Decodable>(_ script: String, as type: T.Type = T.self) async throws -> T {
        try await evaluateJavaScript(script).decode(T.self)
    }

    // MARK: Page

    /// The page's zoom factor: 1 is actual size. Observable; it tracks
    /// changes made here, not ones made to ``nativeView`` directly.
    public var pageZoom: Double = 1 {
        didSet {
            nativeView.pageZoom = pageZoom
            // WebKit may clamp the factor.
            if nativeView.pageZoom != pageZoom { pageZoom = nativeView.pageZoom }
        }
    }

    /// Finds the next match for `text`, selecting it; returns whether there
    /// was one.
    @discardableResult
    public func find(_ text: String, backwards: Bool = false, caseSensitive: Bool = false) async -> Bool {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = caseSensitive
        configuration.wraps = true
        return await withCheckedContinuation { continuation in
            nativeView.find(text, configuration: configuration) { continuation.resume(returning: $0.matchFound) }
        }
    }

    /// A PNG image of the visible page. Protected (DRM) video is left out
    /// of it, as macOS leaves it out of screenshots.
    public func snapshot() async throws -> Data {
        let image = try await nativeView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { throw SnapshotError() }
        return png
    }

    /// The snapshot could not be encoded as PNG.
    public struct SnapshotError: Error {}

    /// Stops the page and its media.
    public func close() {
        nativeView.stopLoading()
        Task { await nativeView.closeAllMediaPresentations() }
        nativeView.loadHTMLString("", baseURL: nil)
    }

    // MARK: Cookies

    /// Copies the cookies `profile`'s Chromium store has for `url` into this
    /// browser's WebKit store, so a sign-in made in Chromium carries over;
    /// returns how many were copied. Nothing is copied unless you call it:
    /// the two engines otherwise keep separate cookies.
    @discardableResult
    public func importCookies(from profile: CefProfile, for url: URL) async throws -> Int {
        let cookies = try await profile.cookies(for: url).compactMap(Self.webKitCookie)
        let store = nativeView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            await store.setCookie(cookie)
        }
        return cookies.count
    }

    /// `cookie` as WebKit should store it. A host-only cookie, whose domain
    /// Chromium gives without a leading dot, is passed by origin so that
    /// WebKit does not widen it to the host's subdomains.
    package static func webKitCookie(_ cookie: CefProfile.Cookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name, .value: cookie.value, .path: cookie.path.isEmpty ? "/" : cookie.path,
        ]
        if cookie.domain.hasPrefix(".") {
            properties[.domain] = cookie.domain
        } else if let origin = URL(string: "\(cookie.isSecure ? "https" : "http")://\(cookie.domain)/") {
            properties[.originURL] = origin
        }
        if cookie.isSecure { properties[.secure] = "TRUE" }
        if cookie.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires = cookie.expirationDate { properties[.expires] = expires }
        switch cookie.sameSite {
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        case .none, .unspecified: break
        }
        return HTTPCookie(properties: properties)
    }

    // MARK: Choosing an engine

    /// Hosts of streaming services whose web players require FairPlay (in
    /// Safari) or Widevine with Verified Media Path, which CefSwift's
    /// Chromium does not have. Subdomains match. Edit it to suit your app.
    public static var protectedStreamingHosts: Set<String> = [
        "netflix.com", "disneyplus.com", "primevideo.com", "max.com", "hbomax.com", "hulu.com",
        "tv.apple.com", "peacocktv.com", "paramountplus.com", "crunchyroll.com", "hotstar.com",
        "jiocinema.com", "sonyliv.com", "zee5.com", "nowtv.com", "canalplus.com", "dazn.com",
    ]

    /// Whether `url` belongs to one of ``protectedStreamingHosts``.
    public static func prefersSystemEngine(for url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.scheme == "https" || url.scheme == "http" else { return false }
        return protectedStreamingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: Private

    /// `Version/<major.minor> Safari/605.1.15`, with the installed Safari's
    /// version (Safari ships with macOS and shares its WebKit).
    package static let safariApplicationName: String = {
        let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let version = (info?["CFBundleShortVersionString"] as? String)
            ?? "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0"
        return "Version/\(version) Safari/605.1.15"
    }()

    package static func webKitScript(for script: CefUserScript) -> WKUserScript {
        var source = script.source
        if !script.matches.isEmpty || !script.excludeMatches.isEmpty {
            func regex(_ patterns: [String]) -> String {
                let alternatives = patterns.map { pattern in
                    pattern.split(separator: "*", omittingEmptySubsequences: false)
                        .map { NSRegularExpression.escapedPattern(for: String($0)) }
                        .joined(separator: ".*")
                }
                let text = "^(?:" + alternatives.joined(separator: "|") + ")$"
                return String(decoding: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
            }
            var conditions: [String] = []
            if !script.matches.isEmpty { conditions.append("new RegExp(\(regex(script.matches))).test(location.href)") }
            if !script.excludeMatches.isEmpty {
                conditions.append("!new RegExp(\(regex(script.excludeMatches))).test(location.href)")
            }
            source = "if (\(conditions.joined(separator: " && "))) (function () {\n\(source)\n})();"
        }
        return WKUserScript(
            source: source,
            injectionTime: script.injectionTime == .documentEnd ? .atDocumentEnd : .atDocumentStart,
            forMainFrameOnly: script.frames == .mainFrame, in: .page)
    }

    private func observe() {
        let sync: @Sendable (WKWebView, Any) -> Void = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        observations = [
            nativeView.observe(\.url, options: [.initial, .new], changeHandler: sync),
            nativeView.observe(\.title, options: [.new], changeHandler: sync),
            nativeView.observe(\.isLoading, options: [.new], changeHandler: sync),
            nativeView.observe(\.estimatedProgress, options: [.new], changeHandler: sync),
            nativeView.observe(\.canGoBack, options: [.new], changeHandler: sync),
            nativeView.observe(\.canGoForward, options: [.new], changeHandler: sync),
            nativeView.observe(\.hasOnlySecureContent, options: [.new], changeHandler: sync),
        ]
    }

    private func sync() {
        let view = nativeView
        if url != view.url { url = view.url }
        if title != view.title ?? "" { title = view.title ?? "" }
        if isLoading != view.isLoading { isLoading = view.isLoading }
        if estimatedProgress != view.estimatedProgress { estimatedProgress = view.estimatedProgress }
        if canGoBack != view.canGoBack { canGoBack = view.canGoBack }
        if canGoForward != view.canGoForward { canGoForward = view.canGoForward }
        if hasOnlySecureContent != view.hasOnlySecureContent { hasOnlySecureContent = view.hasOnlySecureContent }
    }

    private final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var browser: SystemBrowser?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.targetFrame?.isMainFrame ?? true, let browser, let decide = browser.decidePolicy else {
                return .allow
            }
            let navigation = Navigation(
                url: action.request.url,
                hasUserGesture: action.navigationType == .linkActivated || action.navigationType == .formSubmitted)
            return decide(browser, navigation) == .allow ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = action.request.url, let browser else { return nil }
            if let onOpenWindow = browser.onOpenWindow {
                onOpenWindow(browser, url)
            } else {
                browser.load(url)
            }
            return nil
        }
    }
}

// MARK: Website data stores

extension SystemBrowser {
    /// The stores made so far, one per profile, kept while the profile is.
    private static let dataStores = NSMapTable<CefProfile, WKWebsiteDataStore>.weakToStrongObjects()

    /// The WebKit website data store for `profile`: the default store for
    /// the default profile, an in-memory one for an incognito profile, and
    /// a persistent one named by ``dataStoreIdentifier(_:)`` otherwise.
    static func dataStore(for profile: CefProfile) -> WKWebsiteDataStore {
        if let store = dataStores.object(forKey: profile) { return store }
        let store: WKWebsiteDataStore
        if profile === CefProfile.default {
            store = .default()
        } else if profile.isIncognito {
            store = .nonPersistent()
        } else {
            store = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier(profile.id))
        }
        dataStores.setObject(store, forKey: profile)
        return store
    }

    /// The persistent WebKit store's identifier for a profile identifier:
    /// a UUID derived from it, the same on every launch.
    package static func dataStoreIdentifier(_ id: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("CefSwift profile \(id)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // name-based UUID (version 5 layout)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
