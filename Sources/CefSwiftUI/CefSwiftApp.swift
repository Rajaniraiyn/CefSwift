import SwiftUI
import CCefAppKit
@_exported import CefKit

/// A SwiftUI `App` that embeds Chromium.
///
/// Conform your `@main` type to `CefSwiftApp` instead of `App`. Before
/// SwiftUI starts, CefSwift installs the `NSApplication` subclass Chromium
/// requires and initializes the runtime with ``cefConfiguration``.
///
/// ```swift
/// @main
/// struct MyApp: CefSwiftApp {
///     static var cefConfiguration: CefConfiguration { .embedded }
///
///     var body: some Scene {
///         WindowGroup { CefWebView(url: URL(string: "https://example.com")!) }
///     }
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
    /// Runs SwiftUI's own `App.main()`. Inside this extension the call binds
    /// statically to SwiftUI's implementation rather than to
    /// `CefSwiftApp.main()`, which is what lets the latter wrap it.
    @MainActor static func launchSwiftUIRuntime() {
        main()
    }
}

extension CefSwiftApp {
    /// The `@main` entry point: initializes Chromium, then runs the SwiftUI
    /// app. If Chromium cannot start, prints what went wrong and how to fix
    /// it, and exits with status 1.
    @MainActor public static func main() {
        // Must precede every other NSApp access, including SwiftUI's.
        CEFApplication.install()
        do {
            try CefRuntime.shared.initialize(configuration: Self.cefConfiguration)
        } catch .anotherInstanceRunning {
            exit(0)  // the running instance has been told about this launch
        } catch {
            reportBootstrapFailure(error)
        }
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
        case .notInitialized, .browserClosed, .operationFailed, .anotherInstanceRunning:
            lines.append(String(describing: error))
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
        exit(1)
    }
}
