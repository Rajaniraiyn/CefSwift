import AppKit
import CefSwiftUI
import SwiftUI

/// A tabbed web browser composed of features, each built from CefSwift's
/// public API (`Features/`) on a small core (`Core/`): Chromium's own
/// windows and tabs with the browser's tab rail and toolbar over them, and
/// the points features plug into (``BrowserFeature``).
///
/// This is a trimmed copy of CefSwift's Browser example
/// (https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser),
/// whose other features (private windows, page info, Chromium's panels,
/// passkeys, WebKit tabs for streaming, the task manager, …) are folders
/// you can copy into `Features/` and list below.
@main
struct BrowserApp: CefSwiftApp {
    /// The browser's features, in the order their toolbar items, menu
    /// commands and settings appear. Delete a line, and the feature's
    /// folder, to build the browser without it.
    static let features = BrowserFeatures {
        AddressBar()
        Bookmarks()
        History()
        StartPage()
        FindBar()
        Downloads()
        Extensions()
        TabDiscarding()
    }

    static var runtimeConfiguration: CefRuntime.Configuration { .browser }

    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        BrowserScene(features: Self.features, controller: delegate.controller)
    }
}

/// Starts the browser once the app has launched.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = BrowserController(features: BrowserApp.features)

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Task { await controller.openWindow() } }
        return true
    }
}
