import CefKit
import Foundation
import SwiftUI

/// One launchable demo in the catalog. The `kind` selects which hosting mode /
/// configuration the demo window builds.
struct LauncherDemo: Identifiable, Hashable {
    typealias ID = String

    let id: ID
    let title: String
    let subtitle: String
    let symbol: String
    let kind: Kind

    /// How the demo window hosts CEF + which configuration it exercises.
    enum Kind: Hashable {
        /// Windowed Alloy `CefWebView` (CEF renders into a child NSView).
        case windowedAlloy(url: URL)
        /// OSR / Metal `CefMetalWebView` (offscreen → IOSurface → CALayer).
        case osrMetal(url: URL)
        /// Full Chrome-runtime window (`CefChromeWindow`, inverted ownership).
        /// Handled specially (opens a CEF-owned window, not a SwiftUI scene).
        case chromeRuntime(url: URL)
        /// OSR view backed by an incognito profile.
        case incognitoProfile(url: URL)
        /// OSR view backed by a named persistent profile.
        case persistentProfile(url: URL, profileName: String)
        /// A custom-scheme page exercising the `window.cefswift` JS bridge.
        case jsBridge
        /// A page that triggers permission + JS-dialog prompts.
        case dialogsAndPermissions
        /// A page with a download link.
        case downloads
        /// A page with various link/popup types — drives the window-open
        /// disposition handler (Part B), OSR-safe.
        case popups
    }

    static let catalog: [LauncherDemo] = [
        LauncherDemo(
            id: "alloy",
            title: "Windowed Alloy",
            subtitle: "CefWebView — CEF renders into a child NSView. Max compatibility.",
            symbol: "rectangle.inset.filled",
            kind: .windowedAlloy(url: URL(string: "https://example.com")!)),
        LauncherDemo(
            id: "chrome",
            title: "Chrome Runtime Window",
            subtitle: "CefChromeWindow — full Chrome runtime + SwiftUI overlay (chrome:// works).",
            symbol: "macwindow.on.rectangle",
            kind: .chromeRuntime(url: URL(string: "https://duckduckgo.com")!)),
        LauncherDemo(
            id: "osr",
            title: "OSR / Metal",
            subtitle: "CefMetalWebView — offscreen → IOSurface → CALayer. Native UI composites over it.",
            symbol: "square.stack.3d.up.fill",
            kind: .osrMetal(url: URL(string: "https://animejs.com")!)),
        LauncherDemo(
            id: "incognito",
            title: "Incognito Profile",
            subtitle: "An OSR view in a private (off-the-record) profile — no cookies persist.",
            symbol: "eyeglasses",
            kind: .incognitoProfile(url: URL(string: "https://example.com")!)),
        LauncherDemo(
            id: "persistent",
            title: "Persistent Profile",
            subtitle: "An OSR view in a named on-disk profile — cookies/storage survive relaunch.",
            symbol: "externaldrive.fill",
            kind: .persistentProfile(url: URL(string: "https://example.com")!, profileName: "demo")),
        LauncherDemo(
            id: "bridge",
            title: "Custom Scheme + JS Bridge",
            subtitle: "A launcher:// page calling window.cefswift — native ↔ JS round-trips.",
            symbol: "point.3.connected.trianglepath.dotted",
            kind: .jsBridge),
        LauncherDemo(
            id: "dialogs",
            title: "Permissions & JS Dialogs",
            subtitle: "alert / confirm / prompt and a geolocation permission request.",
            symbol: "exclamationmark.bubble.fill",
            kind: .dialogsAndPermissions),
        LauncherDemo(
            id: "downloads",
            title: "Downloads",
            subtitle: "A download link — saved to ~/Downloads via the download delegate.",
            symbol: "arrow.down.circle.fill",
            kind: .downloads),
        LauncherDemo(
            id: "popups",
            title: "Popups & New Tabs",
            subtitle: "target=_blank, window.open, ⌘/middle-click — routed by the window-open handler.",
            symbol: "arrow.up.forward.app.fill",
            kind: .popups),
    ]
}
