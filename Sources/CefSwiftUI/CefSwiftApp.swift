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

    /// Explains why Chromium could not start, then exits with status 1.
    @MainActor private static func reportBootstrapFailure(_ error: CefError) -> Never {
        var message = "CefSwift: could not start Chromium. \(error)\n"
        if case .initializationFailed = error {
            message += "Chromium's log (CefConfiguration.logFile) has the details.\n"
        }
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }
}
