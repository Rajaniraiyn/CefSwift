import AppKit
import CefKit
import SwiftUI

extension CefBrowserWindow {
    /// Where a SwiftUI toolbar sits in a browser window.
    public enum ToolbarPlacement: Sendable {
        /// In the title bar, beside the window buttons — the unified look of
        /// Safari. The window title is hidden; show it yourself if you want it.
        case titleBar
        /// In its own row between the title bar and the page.
        case belowTitleBar
    }

    /// Gives the window a SwiftUI toolbar — your address bar, navigation
    /// buttons, tab controls. The view observes state as usual, so binding
    /// it to ``browser`` keeps it current.
    ///
    /// ```swift
    /// let window = CefBrowserWindow(browser: browser)
    /// window.setToolbar { AddressBar(browser: browser) }
    /// window.show()
    /// ```
    public func setToolbar(placement: ToolbarPlacement = .titleBar, @ViewBuilder _ content: () -> some View) {
        let hosting = NSHostingView(rootView: content())
        switch placement {
        case .belowTitleBar:
            hosting.sizingOptions = [.intrinsicContentSize]
            topAccessory = hosting
        case .titleBar:
            guard let nsWindow else { return }
            let provider = ToolbarItemProvider(view: hosting)
            let toolbar = NSToolbar(identifier: "CefBrowserWindow.toolbar")
            toolbar.delegate = provider
            toolbar.displayMode = .iconOnly
            // NSToolbar holds its delegate weakly; tie its lifetime to the toolbar.
            objc_setAssociatedObject(toolbar, &ToolbarItemProvider.associationKey, provider, .OBJC_ASSOCIATION_RETAIN)
            nsWindow.toolbar = toolbar
            nsWindow.toolbarStyle = .unified
            nsWindow.titleVisibility = .hidden
        }
    }
}

/// Supplies the single, full-width toolbar item that hosts the SwiftUI view.
@MainActor
private final class ToolbarItemProvider: NSObject, NSToolbarDelegate {
    nonisolated(unsafe) static var associationKey = 0
    private static let itemIdentifier = NSToolbarItem.Identifier("CefBrowserWindow.content")

    private let view: NSView

    init(view: NSView) {
        self.view = view
        super.init()
        view.translatesAutoresizingMaskIntoConstraints = false
        // Take whatever width the title bar can spare.
        let fill = view.widthAnchor.constraint(equalToConstant: 10_000)
        fill.priority = .defaultLow
        NSLayoutConstraint.activate([fill, view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320)])
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.itemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = view
        return item
    }
}
