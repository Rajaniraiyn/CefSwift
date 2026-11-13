import CCef
import Foundation
import CefBase

/// A URL scheme of your own, such as `myapp://`.
///
/// Declare schemes in ``CefRuntime/Configuration/customSchemes``. Chromium requires
/// every process to register the same schemes; CefSwift passes the list to
/// helper processes on their command line, and the helper executable that
/// `swift package cef bundle` builds registers it there. Serve content with
/// ``CefRuntime/registerSchemeHandler(scheme:domain:handler:)``.
///
/// ```swift
/// config.customSchemes = [CefCustomScheme(name: "myapp")]
/// // … after initialize:
/// CefRuntime.shared.registerSchemeHandler(
///     scheme: "myapp",
///     handler: CefDirectorySchemeHandler(directory: webRootURL))
/// // pages can now load myapp://anyhost/index.html
/// ```
public struct CefCustomScheme: Sendable, Equatable {
    /// How Chromium treats the scheme, mirroring `cef_scheme_options_t`.
    public struct Options: OptionSet, Sendable, Equatable {
        public let rawValue: Int32
        public init(rawValue: Int32) { self.rawValue = rawValue }

        /// URLs have a host and resolve relative URLs like `https`. Most app
        /// schemes want this.
        public static let standard = Options(rawValue: 1 << 0)
        /// The security rules of `file` URLs.
        public static let local = Options(rawValue: 1 << 1)
        /// Only pages of the same scheme can display its content.
        public static let displayIsolated = Options(rawValue: 1 << 2)
        /// Pages are secure contexts, like `https`, so service workers and
        /// secure cookies work.
        public static let secure = Options(rawValue: 1 << 3)
        /// Other origins may make CORS requests to it. Requires ``standard``.
        public static let corsEnabled = Options(rawValue: 1 << 4)
        /// Its content bypasses Content Security Policy. Requires ``standard``.
        public static let cspBypassing = Options(rawValue: 1 << 5)
        /// The Fetch API can load it.
        public static let fetchEnabled = Options(rawValue: 1 << 6)
    }

    /// The scheme name in lowercase, without `://`, such as `"myapp"`. It
    /// must not be a built-in scheme such as `http` or `file`.
    public var name: String

    /// How Chromium treats the scheme. The default suits serving an app's
    /// own web content.
    public var options: Options

    /// Creates a custom scheme declaration.
    public init(name: String, options: Options = [.standard, .secure, .corsEnabled, .fetchEnabled]) {
        self.name = name
        self.options = options
    }
}

// MARK: - Registration in every process

extension CefCustomScheme {
    /// The scheme as `CefSchemeList` carries it to helper processes.
    var entry: CefSchemeList.Entry { (name, options.rawValue) }

    /// Encodes a scheme list as the value of the helper switch.
    static func serialize(_ schemes: [CefCustomScheme]) -> String {
        CefSchemeList.encode(schemes.map(\.entry))
    }
}
