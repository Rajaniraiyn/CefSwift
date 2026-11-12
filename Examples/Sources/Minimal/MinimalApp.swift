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
/// - `-sandbox YES` runs the helper processes in Chromium's sandbox.
/// - `-memoryPolicy standard|reduced|minimal` overrides the preset's
///   ``CefMemoryPolicy``.
/// - `-benchmark YES` prints `cefswift-benchmark loaded <seconds since 1970>
///   <address>` each time a page finishes loading, and quits when standard
///   input closes. `Scripts/measure-footprint.py` drives it.
@main
struct MinimalApp: CefSwiftApp {
    static var cefConfiguration: CefConfiguration {
        var configuration = CefConfiguration.embedded
        if let path = UserDefaults.standard.string(forKey: "cacheDirectory") {
            configuration.rootCacheDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        configuration.isSandboxEnabled = UserDefaults.standard.bool(forKey: "sandbox")
        switch UserDefaults.standard.string(forKey: "memoryPolicy") {
        case "standard": configuration.memoryPolicy = .standard
        case "reduced": configuration.memoryPolicy = .reduced
        case "minimal": configuration.memoryPolicy = .minimal
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
