import CCef
import Foundation

/// A custom URL scheme registered with CEF in every process.
///
/// Declare custom schemes up front via ``CefConfiguration/customSchemes``;
/// CEF requires scheme registration to happen identically in the browser
/// process *and* every subprocess, before initialization. CefSwift automates
/// the subprocess side: the browser process forwards the scheme list to each
/// helper on its command line (`--cefswift-schemes=…`) and
/// ``CefRuntime/helperMain()`` re-registers them there.
///
/// Serve content for a custom scheme with
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
    /// Scheme behavior flags, mirroring CEF's `cef_scheme_options_t`.
    public struct Options: OptionSet, Sendable, Equatable {
        public let rawValue: Int32
        public init(rawValue: Int32) { self.rawValue = rawValue }

        /// Standard-scheme semantics (URL canonicalization, host/origin,
        /// relative URL resolution). Most app schemes want this.
        public static let standard = Options(rawValue: 1 << 0)
        /// Same security rules as `file://` (no cross-origin loads into it).
        public static let local = Options(rawValue: 1 << 1)
        /// Content can only be displayed from same-scheme pages.
        public static let displayIsolated = Options(rawValue: 1 << 2)
        /// Treated as secure context (like `https://`); unblocks service
        /// workers, secure cookies, mixed-content rules.
        public static let secure = Options(rawValue: 1 << 3)
        /// May receive CORS requests from other origins (requires
        /// ``standard``).
        public static let corsEnabled = Options(rawValue: 1 << 4)
        /// May bypass Content-Security-Policy (requires ``standard``).
        public static let cspBypassing = Options(rawValue: 1 << 5)
        /// May be the target of Fetch API requests.
        public static let fetchEnabled = Options(rawValue: 1 << 6)
    }

    /// The scheme name, e.g. `"myapp"` (lowercase, no `://`). Must not be a
    /// built-in scheme (http, https, file, ftp, about, data).
    public var name: String

    /// Behavior flags. The default makes the scheme a fetchable, secure,
    /// CORS-capable standard scheme — the right shape for serving app UI.
    public var options: Options

    /// Creates a custom scheme declaration.
    public init(name: String, options: Options = [.standard, .secure, .corsEnabled, .fetchEnabled]) {
        self.name = name
        self.options = options
    }
}

// MARK: - Cross-process plumbing (browser → helper command line)

extension CefCustomScheme {
    /// The switch the browser process appends to every child process command
    /// line so helpers can mirror the scheme registration
    /// (`--cefswift-schemes=name:options,name:options`).
    static let childProcessSwitchName = "cefswift-schemes"

    /// Serializes a scheme list into the child-process switch value.
    static func serialize(_ schemes: [CefCustomScheme]) -> String {
        schemes.map { "\($0.name):\($0.options.rawValue)" }.joined(separator: ",")
    }

    /// Parses a child-process switch value back into a scheme list.
    /// Malformed entries are dropped (a helper must never crash on argv).
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

    /// Extracts the scheme list from a helper process's argv, or `[]` when
    /// the switch is absent.
    static func parse(fromArguments arguments: [String]) -> [CefCustomScheme] {
        let prefix = "--\(childProcessSwitchName)="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return [] }
        return parse(String(argument.dropFirst(prefix.count)))
    }
}

/// Shared scheme-registrar plumbing for `cef_app_t.on_register_custom_schemes`
/// (used by both the browser-process app handler and the helper-process one).
enum CefSchemeRegistration {
    /// Registers `schemes` with a CEF scheme registrar. The registrar is a
    /// scoped (non-refcounted) object borrowed for the duration of the call.
    static func register(
        _ schemes: [CefCustomScheme],
        with registrar: UnsafeMutablePointer<cef_scheme_registrar_t>
    ) {
        for scheme in schemes {
            CefStringUtil.withCefString(scheme.name) { name in
                _ = registrar.pointee.add_custom_scheme?(registrar, name, scheme.options.rawValue)
            }
        }
    }
}
