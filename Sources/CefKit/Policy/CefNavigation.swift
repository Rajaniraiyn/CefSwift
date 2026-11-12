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
    /// The address of the request that is challenged, such as
    /// `"http://intranet.example/reports"`.
    public var origin: String
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

    public init(origin: String, isProxy: Bool, host: String, port: Int, realm: String, scheme: String) {
        self.origin = origin
        self.isProxy = isProxy
        self.host = host
        self.port = port
        self.realm = realm
        self.scheme = scheme
    }
}
