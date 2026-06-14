import SwiftUI
import CCefAppKit
@_exported import CefKit

/// The one-line bootstrap for a SwiftUI app embedding CEF.
///
/// Conform your `@main` type to ``CefSwiftApp`` instead of `SwiftUI.App` and CefSwift
/// takes care of the entire CEF startup dance before SwiftUI launches:
///
/// 1. Installs `CEFApplication` (an `NSApplication` subclass conforming to CEF's
///    `CrAppControlProtocol`) **before** anything touches `NSApp`.
/// 2. Initializes the CEF runtime with ``cefConfiguration``
///    (`CefRuntime.shared.initialize(configuration:)`).
/// 3. Hands control to SwiftUI's regular `App.main()`.
///
/// ```swift
/// @main
/// struct MyApp: CefSwiftApp {
///     var body: some Scene {
///         WindowGroup { CefWebView(url: URL(string: "https://example.com")!) }
///     }
/// }
/// ```
///
/// Customize startup by overriding ``cefConfiguration``:
///
/// ```swift
/// static var cefConfiguration: CefConfiguration {
///     var config = CefConfiguration.default
///     config.remoteDebuggingPort = 9222
///     return config
/// }
/// ```
public protocol CefSwiftApp: SwiftUI.App {
    /// The configuration used to initialize the CEF runtime at launch.
    ///
    /// Defaults to ``CefConfiguration/default``.
    @MainActor static var cefConfiguration: CefConfiguration { get }
}

extension CefSwiftApp {
    /// Default configuration: ``CefConfiguration/default``.
    @MainActor public static var cefConfiguration: CefConfiguration { .default }
}

extension SwiftUI.App {
    /// Launches the standard SwiftUI app lifecycle.
    ///
    /// Dispatch subtlety (this is why this method exists): `static func main()` is *not* a
    /// requirement of `SwiftUI.App` — it is provided in a protocol *extension*, so every call
    /// to it is **statically** dispatched. Inside this `extension App`, the unqualified call
    /// below therefore resolves to SwiftUI's own `App.main()` extension method — never to the
    /// more-specific `CefSwiftApp.main()` shadow (which only wins overload resolution when the
    /// call site's context is the concrete conforming type, e.g. the `@main` entry point).
    /// This gives us a non-recursive path from `CefSwiftApp.main()` into SwiftUI's launcher.
    @MainActor static func launchSwiftUIRuntime() {
        main()
    }
}

extension CefSwiftApp {
    /// The `@main` entry point: bootstraps CEF, then runs the SwiftUI app.
    ///
    /// Because `Self` conforms to the refined ``CefSwiftApp`` protocol, the `@main` attribute's
    /// statically-resolved call to `Self.main()` picks this overload in preference to
    /// `SwiftUI.App`'s extension method. After CEF is up, SwiftUI's original `main()` is
    /// reached via ``SwiftUI/App/launchSwiftUIRuntime()`` (see its doc comment for why that
    /// does not recurse).
    ///
    /// On CEF initialization failure this prints actionable diagnostics to standard error and
    /// terminates the process with exit code 1.
    @MainActor public static func main() {
        // 1. NSApplication must be instantiated as CEFApplication before any NSApp touch
        //    (CEF requires CrAppControlProtocol conformance on the application object).
        //    CefRuntime.initialize also ensures this, but installing here guarantees ordering
        //    even if SwiftUI internals touch NSApp earlier than expected. Idempotent.
        CEFApplication.install()

        // 2. Bring up the CEF runtime.
        do {
            try CefRuntime.shared.initialize(configuration: Self.cefConfiguration)
        } catch {
            reportBootstrapFailure(error)
        }

        // 3. Hand off to SwiftUI's default App.main() (statically dispatched — no recursion).
        launchSwiftUIRuntime()
    }

    /// Prints a human-actionable diagnosis of a CEF bootstrap failure and exits.
    @MainActor private static func reportBootstrapFailure(_ error: CefError) -> Never {
        var lines: [String] = ["CefSwift: failed to initialize the CEF runtime."]

        switch error {
        case .frameworkNotFound(let detail):
            lines.append("Chromium Embedded Framework could not be located: \(detail)")
            lines.append("Most likely this executable is not running from a bundled .app.")
        case .loadFailed(let detail):
            lines.append("Chromium Embedded Framework failed to load: \(detail)")
        case .apiHashMismatch(let expected, let actual):
            lines.append("CEF API hash mismatch (expected \(expected), got \(actual)).")
            lines.append("The bundled framework does not match the CEF version this package was built against.")
            lines.append("Re-run `swift package cef download` and re-bundle to refresh the framework.")
        case .initializationFailed(let exitCode):
            lines.append("cef_initialize failed (exit code \(exitCode)).")
            lines.append("Check the CEF log (see CefConfiguration.logFile / logSeverity) for details.")
        case .alreadyInitialized:
            lines.append("CEF was already initialized. Initialize the runtime exactly once per process.")
        case .notInitialized:
            lines.append("CEF runtime was used before initialization.")
        }

        lines.append("")
        lines.append("How to fix:")
        lines.append("  • Run your app from a proper bundle: `swift package --allow-writing-to-package-directory \\")
        lines.append("      --allow-network-connections all cef bundle --product <YourProduct>` then `open` the produced .app.")
        lines.append("  • For ad-hoc runs, point CEF_FRAMEWORK_PATH at a 'Chromium Embedded Framework.framework' binary,")
        lines.append("    or set CefConfiguration.frameworkDirectory explicitly in `cefConfiguration`.")
        lines.append("  • `swift package cef info` shows the pinned CEF version and cache state.")

        let message = lines.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(message.utf8))
        // Print guidance to stderr and exit(1) — same user-visible effect as fatalError,
        // but without a crash report burying the actionable message.
        exit(1)
    }
}
