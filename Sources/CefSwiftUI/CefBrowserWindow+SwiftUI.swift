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
    /// Each closure runs once, when you call this method, to build its view.
    /// The views it builds stay live: SwiftUI re-renders them as the
    /// observable state they read changes, so bind them to ``browser`` or
    /// your own models rather than passing values captured at call time.
    /// Call the method again to replace the toolbar.
    ///
    /// The toolbar is installed as soon as the window exists — immediately
    /// for any window you create.
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
        let provider = ToolbarItemProvider(
            leading: NSHostingView(rootView: leading()),
            principal: NSHostingView(rootView: principal()),
            trailing: NSHostingView(rootView: trailing()))
        withWindow { provider.install(in: $0) }
    }

    /// A toolbar with only a centered view.
    public func setToolbar(@ViewBuilder principal: () -> some View) {
        setToolbar(leading: { EmptyView() }, principal: principal, trailing: { EmptyView() })
    }

    /// Shows a small SwiftUI view inside this window's tab in the native tab
    /// bar — a favicon, a loading spinner, an audio indicator.
    ///
    /// `content` runs once; the view it builds updates with the observable
    /// state it reads, such as ``CefBrowser/favicon`` and
    /// ``CefBrowser/isLoading``. The accessory is installed as soon as the
    /// window exists.
    public func setTabAccessory(@ViewBuilder _ content: () -> some View) {
        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = [.intrinsicContentSize]
        withWindow { $0.tab.accessoryView = hosting }
    }
}

extension View {
    /// Makes this view the anchor of Chromium's surfaces in the
    /// ``CefBrowserWindow`` it is in, such as a view of the window's
    /// toolbar: Chromium's bubbles appear beneath it instead of where
    /// Chrome's toolbar would be.
    ///
    /// Without `kinds`, the view becomes the window's
    /// ``CefChromiumUI/anchor``, which every surface that hangs from Chrome's
    /// toolbar follows; with them, it is the anchor of those kinds in
    /// ``CefChromiumUI/anchors``, Chromium's surfaces and your own interface
    /// for them alike. The anchor is removed when the view leaves the
    /// window.
    ///
    /// ```swift
    /// AddressField(browser: browser)
    ///     .chromiumSurfaceAnchor(alignment: .trailing)
    /// Button("QR Code", systemImage: "qrcode") { browser.execute(.createQRCode) }
    ///     .chromiumSurfaceAnchor([.qrCode])
    /// ```
    public func chromiumSurfaceAnchor(
        _ kinds: Set<CefChromiumSurface.Kind>? = nil,
        alignment: CefSurfaceAnchor.Alignment = .center,
        spacing: CGFloat = 4
    ) -> some View {
        background(SurfaceAnchorRepresentable(kinds: kinds, alignment: alignment, spacing: spacing))
    }
}

private struct SurfaceAnchorRepresentable: NSViewRepresentable {
    let kinds: Set<CefChromiumSurface.Kind>?
    let alignment: CefSurfaceAnchor.Alignment
    let spacing: CGFloat

    func makeNSView(context: Context) -> SurfaceAnchorView {
        SurfaceAnchorView()
    }

    func updateNSView(_ view: SurfaceAnchorView, context: Context) {
        view.configure(kinds: kinds, alignment: alignment, spacing: spacing)
    }
}

/// An invisible view that registers itself as a surface anchor with the
/// browser window it is in.
private final class SurfaceAnchorView: NSView {
    private var kinds: Set<CefChromiumSurface.Kind>?
    private var alignment = CefSurfaceAnchor.Alignment.center
    private var spacing: CGFloat = 4
    private weak var registeredWindow: CefBrowserWindow?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(kinds: Set<CefChromiumSurface.Kind>?, alignment: CefSurfaceAnchor.Alignment, spacing: CGFloat) {
        unregister()
        self.kinds = kinds
        self.alignment = alignment
        self.spacing = spacing
        register()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unregister()
        register()
    }

    private func register() {
        guard let window, let owner = CefBrowserWindow.owning(window) else { return }
        let anchor = CefSurfaceAnchor.view(self, alignment: alignment, spacing: spacing)
        if let kinds {
            for kind in kinds { owner.chromiumUI.anchors[kind] = anchor }
        } else {
            owner.chromiumUI.anchor = anchor
        }
        registeredWindow = owner
    }

    private func unregister() {
        guard let owner = registeredWindow else { return }
        registeredWindow = nil
        if let kinds {
            for kind in kinds where owner.chromiumUI.anchors[kind]?.isAnchored(to: self) == true {
                owner.chromiumUI.anchors[kind] = nil
            }
        } else if owner.chromiumUI.anchor?.isAnchored(to: self) == true {
            owner.chromiumUI.anchor = nil
        }
    }
}

extension ToolbarItemProvider {
    /// Makes a toolbar of this provider's items the window's toolbar.
    func install(in nsWindow: NSWindow) {
        let provider = self
        let toolbar = NSToolbar(identifier: "CefBrowserWindow.toolbar")
        toolbar.delegate = provider
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [ToolbarItemProvider.principal]
        // NSToolbar holds its delegate weakly; tie its lifetime to the toolbar.
        objc_setAssociatedObject(toolbar, &ToolbarItemProvider.associationKey, provider, .OBJC_ASSOCIATION_RETAIN)
        WindowButtonCentering.apply(to: nsWindow)
        // AppKit makes room for a new toolbar by growing the window; keep
        // the frame the window was given instead.
        let frame = nsWindow.frame
        nsWindow.toolbar = toolbar
        nsWindow.toolbarStyle = .unifiedCompact
        nsWindow.titleVisibility = .hidden
        nsWindow.setFrame(frame, display: false)
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

/// Centers the window buttons vertically in the toolbar, as in any unified
/// AppKit window.
///
/// AppKit centers them only when the window's frame view is exactly
/// `NSThemeFrame`; Chromium's windows use a subclass, so the buttons stay at
/// the top of a title bar the toolbar has made taller. The subclass is given
/// the (private) answer `NSThemeFrame` would give for windows with a
/// toolbar. Nothing changes if the class answers itself or AppKit stops
/// asking.
@MainActor
private enum WindowButtonCentering {
    private static var adjustedClasses: Set<ObjectIdentifier> = []

    static func apply(to window: NSWindow) {
        guard let frameView = window.contentView?.superview, let frameClass = object_getClass(frameView),
              frameClass != NSClassFromString("NSThemeFrame"),
              adjustedClasses.insert(ObjectIdentifier(frameClass)).inserted
        else { return }
        let answer: @convention(block) (NSView) -> Bool = { view in view.window?.toolbar != nil }
        // Adds the method to this class only; fails harmlessly if it has one.
        class_addMethod(
            frameClass, NSSelectorFromString("_shouldCenterTrafficLights"),
            imp_implementationWithBlock(answer), "B@:")
    }
}
