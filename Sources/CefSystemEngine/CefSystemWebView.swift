import AppKit
import CefKit
import SwiftUI
import WebKit

/// A view that displays a ``CefSystemBrowser``: a page in the system's
/// WebKit, for sites such as streaming services that need Safari's
/// FairPlay.
///
/// ```swift
/// @State private var movie = CefSystemBrowser(url: URL(string: "https://www.netflix.com/")!)
///
/// CefSystemWebView(movie)
///     .navigationTitle(movie.title)
/// ```
///
/// The view never closes the browser; call ``CefSystemBrowser/close()``
/// when you are done with it.
public struct CefSystemWebView: NSViewRepresentable {
    private let browser: CefSystemBrowser

    public init(_ browser: CefSystemBrowser) {
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
