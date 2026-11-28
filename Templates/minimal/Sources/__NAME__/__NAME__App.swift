import AppKit
import CefSwiftUI
import SwiftUI

/// One window with one web page, on the `.embedded` configuration:
/// Chromium without Chrome's background services.
///
/// Launch arguments (read as user defaults):
///
/// - `-url <address>` shows that page.
/// - `-smoke YES` prints `PASS loaded <address>` once the page has loaded
///   and quits, or prints `FAIL …` and exits with status 1 after 60 seconds.
@main
struct __NAME__App: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration { .embedded }

    @State private var page = CefPage(url: Self.startURL, delegate: SmokeTest.shared)

    var body: some Scene {
        WindowGroup {
            CefWebView(page)
                .navigationTitle(page.title.isEmpty ? "__DISPLAY_NAME__" : page.title)
                .onAppear { SmokeTest.shared.start() }
        }
        .defaultSize(width: 1000, height: 720)
    }

    static var startURL: URL {
        UserDefaults.standard.string(forKey: "url").flatMap(URL.init(string:))
            ?? URL(string: "https://www.swift.org")!
    }
}

/// The `-smoke YES` launch argument: a check that the bundle starts
/// Chromium and loads a page.
@MainActor
final class SmokeTest: CefPageDelegate {
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

    func page(_ page: CefPage, didFinishLoadWithStatus httpStatus: Int) {
        guard isEnabled, !isDone else { return }
        isDone = true
        print("PASS loaded \(page.url?.absoluteString ?? "")")
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
