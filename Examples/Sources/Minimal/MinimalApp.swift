import AppKit
import CefSwiftUI
import SwiftUI

/// The smallest CefSwift app: one window with one `CefWebView`, on the
/// `.embedded` configuration.
///
/// Launch arguments (read as user defaults):
///
/// - `-url <address>` shows that page instead of the built-in one.
/// - `-cacheDirectory <path>` keeps Chromium's data there.
/// - `-sandbox NO` runs the helper processes outside Chromium's sandbox.
/// - `-processPolicy automatic|onDemand|minimal` overrides the preset's
///   ``CefRuntime/ProcessPolicy``.
/// - `-protectedMedia YES` lets Chromium fetch Widevine
///   (``CefRuntime/Configuration/Services/ProtectedMedia/automatic``).
/// - `-benchmark YES` prints `cefswift-benchmark loaded <seconds since 1970>
///   <address>` each time a page finishes loading, and quits when standard
///   input closes. `Scripts/measure-footprint.py` drives it.
@main
struct MinimalApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration {
        var configuration = CefRuntime.Configuration.embedded
        if let path = UserDefaults.standard.string(forKey: "cacheDirectory") {
            configuration.rootCacheDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        if UserDefaults.standard.object(forKey: "sandbox") != nil {
            configuration.isSandboxEnabled = UserDefaults.standard.bool(forKey: "sandbox")
        }
        if UserDefaults.standard.bool(forKey: "protectedMedia") { configuration.services.protectedMedia = .automatic }
        switch UserDefaults.standard.string(forKey: "processPolicy") {
        case "automatic": configuration.processPolicy = .automatic
        case "onDemand": configuration.processPolicy = .onDemand
        case "minimal": configuration.processPolicy = .minimal
        default: break
        }
        return configuration
    }

    @State private var browser = CefBrowser(url: Self.pageURL, delegate: BenchmarkReporter.shared)

    init() {
        BenchmarkReporter.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            CefWebView(browser)
        }
        .defaultSize(width: 900, height: 640)
    }

    static var pageURL: URL {
        UserDefaults.standard.string(forKey: "url").flatMap(URL.init(string:))
            ?? URL(string: "data:text/html,<title>Minimal</title><h1>Hello from CefSwift</h1>")!
    }
}

/// The `-benchmark YES` launch argument: reports each finished load on
/// standard output and quits when standard input closes.
@MainActor
final class BenchmarkReporter: CefBrowserDelegate {
    static let shared = BenchmarkReporter()

    private let isEnabled = UserDefaults.standard.bool(forKey: "benchmark")

    func start() {
        guard isEnabled else { return }
        Thread.detachNewThread {
            while readLine() != nil {}
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func browser(_ browser: CefBrowser, didFinishLoadWithStatus httpStatus: Int) {
        guard isEnabled else { return }
        print("cefswift-benchmark loaded \(Date().timeIntervalSince1970) \(browser.url?.absoluteString ?? "")")
        fflush(stdout)
    }
}
