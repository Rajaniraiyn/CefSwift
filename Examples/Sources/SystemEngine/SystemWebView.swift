import AppKit
import CefKit
import SwiftUI
import WebKit

/// A view that displays a ``SystemPage``: a page in the system's
/// WebKit, for sites such as streaming services that need Safari's
/// FairPlay.
///
/// ```swift
/// @State private var movie = SystemPage(url: URL(string: "https://www.netflix.com/")!)
///
/// SystemWebView(movie)
///     .navigationTitle(movie.title)
/// ```
///
/// The view never closes the page; call ``SystemPage/close()``
/// when you are done with it.
public struct SystemWebView: NSViewRepresentable {
    private let page: SystemPage

    public init(_ page: SystemPage) {
        self.page = page
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        if page.nativeView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let view = page.nativeView
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
