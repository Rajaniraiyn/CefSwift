import AppKit
import CefKit
import SwiftUI

extension CefBrowserWindow {
    /// Gives the window a unified title-bar toolbar built from SwiftUI
    /// views, laid out the way Safari's is: `leading` beside the window
    /// buttons, `principal` centered (your address field), `trailing` at the
    /// far edge. Each view is a native toolbar item, so it picks up the
    /// system's toolbar appearance, and the native tab bar appears beneath
    /// it when the window joins a tab group.
    ///
    /// The views observe state as usual; bind them to ``browser``.
    ///
    /// ```swift
    /// window.setToolbar {
    ///     NavigationButtons(browser: browser)
    /// } principal: {
    ///     AddressField(browser: browser)
    /// } trailing: {
    ///     Button("New Tab", systemImage: "plus", action: openTab)
    /// }
    /// ```
    public func setToolbar(
        @ViewBuilder leading: () -> some View,
        @ViewBuilder principal: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) {
        guard let nsWindow else { return }
        let provider = ToolbarItemProvider(
            leading: NSHostingView(rootView: leading()),
            principal: NSHostingView(rootView: principal()),
            trailing: NSHostingView(rootView: trailing()))
        let toolbar = NSToolbar(identifier: "CefBrowserWindow.toolbar")
        toolbar.delegate = provider
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [ToolbarItemProvider.principal]
        // NSToolbar holds its delegate weakly; tie its lifetime to the toolbar.
        objc_setAssociatedObject(toolbar, &ToolbarItemProvider.associationKey, provider, .OBJC_ASSOCIATION_RETAIN)
        nsWindow.toolbar = toolbar
        nsWindow.toolbarStyle = .unifiedCompact
        nsWindow.titleVisibility = .hidden
    }

    /// A toolbar with only a centered view.
    public func setToolbar(@ViewBuilder principal: () -> some View) {
        setToolbar(leading: { EmptyView() }, principal: principal, trailing: { EmptyView() })
    }

    /// Shows a small SwiftUI view inside this window's tab in the native tab
    /// bar — a favicon, a loading spinner, an audio indicator.
    public func setTabAccessory(@ViewBuilder _ content: () -> some View) {
        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = [.intrinsicContentSize]
        nsWindow?.tab.accessoryView = hosting
    }
}

/// Supplies the toolbar items that host the SwiftUI views.
@MainActor
private final class ToolbarItemProvider: NSObject, NSToolbarDelegate {
    nonisolated(unsafe) static var associationKey = 0
    static let leading = NSToolbarItem.Identifier("CefBrowserWindow.leading")
    static let principal = NSToolbarItem.Identifier("CefBrowserWindow.principal")
    static let trailing = NSToolbarItem.Identifier("CefBrowserWindow.trailing")

    private let views: [NSToolbarItem.Identifier: NSView]

    init(leading: NSView, principal: NSView, trailing: NSView) {
        views = [Self.leading: leading, Self.principal: principal, Self.trailing: trailing]
        super.init()
        for view in views.values {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        // The centered item takes a comfortable width and gives it up as the
        // window narrows.
        let preferred = principal.widthAnchor.constraint(equalToConstant: 640)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([
            preferred,
            principal.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    private var identifiers: [NSToolbarItem.Identifier] {
        [Self.leading, .flexibleSpace, Self.principal, .flexibleSpace, Self.trailing]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let view = views[itemIdentifier] else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = view
        return item
    }
}
