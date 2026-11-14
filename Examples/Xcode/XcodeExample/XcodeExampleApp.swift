import AppKit
import CefSwiftUI
import SwiftUI

/// A SwiftUI app built by an Xcode project rather than SwiftPM: one window
/// with one `CefWebView`. The project adds CefSwift as a package and runs
/// CefSwift's build phase; see docs/bundling.md#xcode.
///
/// Launch arguments (read as user defaults):
///
/// - `-url <address>` shows that page instead of the built-in one.
/// - `-smoke YES` prints `PASS loaded <address>` once the page has loaded
///   and quits with status 0, or prints `FAIL …` and exits with status 1
///   after 60 seconds. Scripts/check-xcode-example.sh runs it.
@main
struct XcodeExampleApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration { .embedded }

    @State private var browser = CefBrowser(url: Self.pageURL, delegate: SmokeTest.shared)

    var body: some Scene {
        WindowGroup {
            ContentView(browser: browser)
                .onAppear { SmokeTest.shared.start() }
        }
        .defaultSize(width: 900, height: 640)
    }

    static var pageURL: URL {
        UserDefaults.standard.string(forKey: "url").flatMap(URL.init(string:))
            ?? URL(string: "data:text/html,<title>Xcode example</title><h1>Hello from an Xcode project</h1>")!
    }
}

struct ContentView: View {
    let browser: CefBrowser

    var body: some View {
        CefWebView(browser)
            .navigationTitle(browser.title.isEmpty ? "Xcode example" : browser.title)
    }
}

// Previews run without Chromium: the web view shows a placeholder.
#Preview {
    ContentView(browser: CefBrowser(url: URL(string: "https://example.com")!))
}

/// The `-smoke YES` launch argument.
@MainActor
final class SmokeTest: CefBrowserDelegate {
    static let shared = SmokeTest()

    private let isEnabled = UserDefaults.standard.bool(forKey: "smoke")
    private var isDone = false

    func start() {
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard !self.isDone else { return }
            print("FAIL the page did not load within 60 seconds")
            exit(1)
        }
    }

    func browser(_ browser: CefBrowser, didFinishLoadWithStatus httpStatus: Int) {
        guard isEnabled, !isDone else { return }
        isDone = true
        print("PASS loaded \(browser.url?.absoluteString ?? "")")
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
