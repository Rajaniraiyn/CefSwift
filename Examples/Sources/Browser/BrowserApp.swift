import AppKit
import CefSwiftUI
import SwiftUI

/// A tabbed web browser composed of features, each built from CefSwift's
/// public API (`Features/`) on a small core (`Core/`): the tabs, their
/// windows, and the points features plug into (``BrowserFeature``).
@main
struct BrowserApp: CefSwiftApp {
    /// The browser's features, in the order their toolbar items, menu
    /// commands and settings appear. Delete a line, and the feature's
    /// folder, to build the browser without it.
    static let features = BrowserFeatures {
        PrivateTabs()
        AddressBar()
        PageInfo()
        Bookmarks()
        History()
        StartPage()
        FindBar()
        StatusBubble()
        SwipeIndicator()
        Appearance()
        Downloads()
        Extensions()
        TabDiscarding()
        ChromiumPanels()
        ChromiumPages()
        Playground()
        WebKitTabs()
        Passkeys()
        TaskManager()
        ChromeTabs()
        SingleInstance()
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

    /// Lets the native tab bar show its "+" button.
    @objc func newWindowForTab(_ sender: Any?) {
        controller.openTab()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { controller.openTab() }
        return true
    }
}
