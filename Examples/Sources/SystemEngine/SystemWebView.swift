import AppKit
import CefKit
import SwiftUI
import WebKit

/// A view that displays a ``SystemBrowser``: a page in the system's
/// WebKit, for sites such as streaming services that need Safari's
/// FairPlay.
///
/// ```swift
/// @State private var movie = SystemBrowser(url: URL(string: "https://www.netflix.com/")!)
///
/// SystemWebView(movie)
///     .navigationTitle(movie.title)
/// ```
///
/// The view never closes the browser; call ``SystemBrowser/close()``
/// when you are done with it.
public struct SystemWebView: NSViewRepresentable {
    private let browser: SystemBrowser

    public init(_ browser: SystemBrowser) {
        self.browser = browser
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        if browser.nativeView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let view = browser.nativeView
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
