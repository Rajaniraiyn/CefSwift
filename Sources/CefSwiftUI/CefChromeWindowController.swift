import AppKit
import CefKit
import Observation
import SwiftUI

/// An observable controller a SwiftUI app holds to open and track
/// ``CefChromeWindow``s — the recommended way to drive the full-browser
/// hosting mode from a SwiftUI `App`.
///
/// Because CEF owns each chrome window's `NSWindow` (it lives outside SwiftUI's
/// `Scene` graph), you don't declare these windows in a `WindowGroup`. Instead
/// hold one controller (e.g. `@State`), open windows from it after the runtime
/// is up, and observe ``windows`` for app-level UI (a window menu, etc.).
///
/// ```swift
/// @main
/// struct BrowserApp: CefSwiftApp {
///     @State private var controller = CefChromeWindowController()
///     var body: some Scene {
///         // A tiny placeholder scene keeps the app alive; the real browser
///         // window is the CEF-owned chrome window opened below.
///         WindowGroup { Color.clear.frame(width: 0, height: 0)
///             .task { controller.open(url: homeURL) { /* overlay */ } }
///         }
///     }
/// }
/// ```
@Observable
@MainActor
public final class CefChromeWindowController {

    /// The currently open chrome windows, in creation order. Updated as
    /// windows open and close.
    public private(set) var windows: [CefChromeWindow] = []

    public init() {}

    /// Opens a new ``CefChromeWindow`` and tracks it in ``windows``.
    ///
    /// - Parameters mirror ``CefChromeWindow/open(url:initialBounds:backgroundColor:delegate:configure:)``.
    /// - Returns: the new window (also retained by CefSwift until destroyed).
    @discardableResult
    public func open(
        url: URL,
        initialBounds: CGRect? = nil,
        backgroundColor: NSColor? = nil,
        delegate: CefBrowserDelegate? = nil,
        configure: ((CefChromeWindow) -> Void)? = nil
    ) -> CefChromeWindow {
        let window = CefChromeWindow.open(
            url: url,
            initialBounds: initialBounds,
            backgroundColor: backgroundColor,
            delegate: delegate,
            configure: configure
        )
        windows.append(window)
        let previousOnClose = window.onClose
        window.onClose = { [weak self, weak window] in
            previousOnClose?()
            guard let self, let window else { return }
            self.windows.removeAll { $0 === window }
        }
        return window
    }

    /// Closes all tracked windows.
    public func closeAll() {
        for window in windows { window.close() }
    }
}
