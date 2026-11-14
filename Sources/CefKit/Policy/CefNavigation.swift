import CCef
import Foundation

/// Whether a navigation may proceed, returned from
/// ``CefBrowserDelegate/browser(_:decidePolicyFor:)``.
public enum CefNavigationDecision: Sendable, Equatable {
    /// Let the navigation proceed.
    case allow
    /// Stop the navigation, for example to handle the URL yourself.
    case cancel
}

/// How a navigation started, Chromium's transition type: of a
/// ``CefNavigationAction`` about to happen, and of a page in the
/// ``CefBrowser/backForwardList``.
public struct CefNavigationTransition: Sendable, Hashable {
    /// What started the navigation.
    public enum Source: Sendable, Hashable {
        /// A link click, or `window.open`.
        case link
        /// Any other explicit navigation, such as `load(_:)`
        /// or an address typed into Chrome's omnibox.
        case explicit
        /// A suggestion Chrome showed (Chrome style).
        case autoBookmark
        /// Content loaded in a subframe by itself.
        case autoSubframe
        /// A subframe navigation the user asked for.
        case manualSubframe
        /// A search Chrome's omnibox generated (Chrome style).
        case generated
        /// A page Chromium opened at the top level by itself
        /// (Chrome style).
        case autoToplevel
        /// A form the user submitted. A form a script submits may
        /// not report this.
        case formSubmit
        case reload
        /// A search keyword (Chrome style).
        case keyword
        case keywordGenerated
        case unknown
    }

    public var source: Source
    /// Whether going back or forward started it.
    public var isBackForward: Bool
    /// Whether a client (script, `meta refresh`) or server
    /// redirect led to it.
    public var isRedirect: Bool
    /// Whether the navigation was a direct load: an address
    /// typed or given, a bookmark.
    public var isDirectLoad: Bool
    /// Whether an app's call started it (`load(_:)`).
    public var isFromAPI: Bool

    /// Creates a value of your own, for previews and tests.
    public init(
        source: Source, isBackForward: Bool = false, isRedirect: Bool = false, isDirectLoad: Bool = false,
        isFromAPI: Bool = false
    ) {
        self.source = source
        self.isBackForward = isBackForward
        self.isRedirect = isRedirect
        self.isDirectLoad = isDirectLoad
        self.isFromAPI = isFromAPI
    }
}

/// Why a browser's render process ended, delivered to
/// ``CefBrowserDelegate/browser(_:renderProcessDidTerminate:)``.
public enum CefTerminationReason: Sendable, Equatable {
    /// The process exited with a non-zero status.
    case abnormal
    /// The process was killed.
    case killed
    /// The process crashed.
    case crashed
    /// The process ran out of memory.
    case outOfMemory
    /// The process failed to launch.
    case launchFailed
    /// The process failed a code-integrity check. Windows only.
    case integrityFailure

    init(cefValue: cef_termination_status_t) {
        switch cefValue {
        case TS_PROCESS_WAS_KILLED: self = .killed
        case TS_PROCESS_CRASHED: self = .crashed
        case TS_PROCESS_OOM: self = .outOfMemory
        case TS_LAUNCH_FAILED: self = .launchFailed
        case TS_INTEGRITY_FAILURE: self = .integrityFailure
        default: self = .abnormal
        }
    }
}

/// An HTTP authentication challenge delivered to
/// ``CefBrowserDelegate/browser(_:credentialFor:)``.
public struct CefAuthenticationChallenge: Sendable, Equatable {
    /// The full address of the request that is challenged, such as
    /// `http://intranet.example/reports`.
    public var url: URL?
    /// Whether the challenge comes from a proxy rather than the server.
    public var isProxy: Bool
    /// The host name of the server or proxy.
    public var host: String
    /// The port of the server or proxy.
    public var port: Int
    /// The authentication realm, or an empty string.
    public var realm: String
    /// The authentication scheme, such as `"basic"`, or an empty string.
    public var scheme: String

    public init(url: URL?, isProxy: Bool, host: String, port: Int, realm: String, scheme: String) {
        self.url = url
        self.isProxy = isProxy
        self.host = host
        self.port = port
        self.realm = realm
        self.scheme = scheme
    }
}
