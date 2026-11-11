import CCef
import Foundation

/// A URL scheme of your own, such as `myapp://`.
///
/// Declare schemes in ``CefConfiguration/customSchemes``. Chromium requires
/// every process to register the same schemes; CefSwift passes the list to
/// helper processes on their command line and ``CefRuntime/helperMain()``
/// registers it there. Serve content with
/// ``CefRuntime/registerSchemeHandler(scheme:domain:handler:)``.
///
/// ```swift
/// config.customSchemes = [CefCustomScheme(name: "myapp")]
/// // … after initialize:
/// CefRuntime.shared.registerSchemeHandler(
///     scheme: "myapp",
///     handler: CefBundleSchemeHandler(directory: webRootURL))
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
    /// The switch that carries the scheme list to helper processes, as
    /// `--cefswift-schemes=name:options,name:options`.
    static let childProcessSwitchName = "cefswift-schemes"

    /// Encodes a scheme list as the switch value.
    static func serialize(_ schemes: [CefCustomScheme]) -> String {
        schemes.map { "\($0.name):\($0.options.rawValue)" }.joined(separator: ",")
    }

    /// Decodes a switch value, skipping malformed entries.
    static func parse(_ serialized: String) -> [CefCustomScheme] {
        serialized.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  let rawOptions = Int32(parts[1])
            else { return nil }
            return CefCustomScheme(name: String(parts[0]), options: Options(rawValue: rawOptions))
        }
    }

    /// The scheme list in a helper's arguments, or `[]` without the switch.
    static func parse(fromArguments arguments: [String]) -> [CefCustomScheme] {
        let prefix = "--\(childProcessSwitchName)="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return [] }
        return parse(String(argument.dropFirst(prefix.count)))
    }

    /// Registers `schemes` from `on_register_custom_schemes`. The registrar
    /// is not reference-counted and is only borrowed.
    static func register(
        _ schemes: [CefCustomScheme],
        with registrar: UnsafeMutablePointer<cef_scheme_registrar_t>
    ) {
        for scheme in schemes {
            CefStringUtil.withCefString(scheme.name) { name in
                _ = registrar.pointee.add_custom_scheme(registrar, name, scheme.options.rawValue)
            }
        }
    }
}
