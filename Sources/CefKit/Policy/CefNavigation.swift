import CCef
import Foundation

/// Verdict for a navigation that is about to start, returned from
/// ``CefBrowserDelegate/browser(_:decidePolicyFor:)``.
public enum CefNavigationDecision: Sendable, Equatable {
    /// Let the navigation proceed.
    case allow
    /// Block the navigation (e.g. to handle an external scheme yourself).
    case cancel
}

/// Why the render process for a browser went away, delivered to
/// ``CefBrowserDelegate/browser(_:renderProcessDidTerminate:)``.
public enum CefTerminationReason: Sendable, Equatable {
    /// Non-zero exit status.
    case abnormal
    /// SIGKILL / task-manager kill.
    case killed
    /// Segmentation fault / crash.
    case crashed
    /// Out of memory.
    case outOfMemory
    /// The child process never launched.
    case launchFailed
    /// Code-integrity failure (Windows; surfaced for completeness).
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
public struct CefAuthChallenge: Sendable, Equatable {
    /// Origin making the authentication request.
    public var origin: String
    /// Whether the host is a proxy server (vs. the origin server).
    public var isProxy: Bool
    /// Server hostname.
    public var host: String
    /// Server port.
    public var port: Int
    /// Authentication realm (may be empty).
    public var realm: String
    /// Authentication scheme, e.g. `"basic"` or `"digest"` (may be empty).
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
