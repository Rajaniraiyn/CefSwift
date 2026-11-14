import AppKit
import CefKit
import Foundation

extension CefChromeWindow {
    /// How Chromium's own interface is presented in this window — its
    /// bubbles, dialogs, find bar and status bubble, and those of tabs:
    /// tab search, the tab group editor — as for a ``CefWindow``
    /// (``CefWindow/chromiumSurfacePolicy``): drawn by Chromium, anchored
    /// under your controls, replaced by your interface, or hidden.
    ///
    /// ```swift
    /// window.chromiumSurfacePolicy.anchor = .view(addressField, alignment: .trailing)
    /// window.setCustomPresentation(for: .qrCode) { surface in showMyQRCode(for: surface.url) }
    /// window.setFindBar { session in MyFindBar(session: session) }
    /// ```
    ///
    /// Each surface belongs to the tab it was opened in
    /// (``CefChromiumSurface/browser``). As Chromium does, switching tabs
    /// closes the bubbles about the tab left (your interface for them is
    /// dismissed too) and keeps a find bar for when the tab comes back.
    ///
    /// While Chrome's tab strip and toolbar are covered
    /// (``showsChromeUI`` off), the bubbles that hang from Chrome's toolbar
    /// go under the app's ``topBar``, at the trailing edge of the page,
    /// unless the policy names an anchor; the
    /// `chromiumSurfaceAnchor(_:alignment:)` modifier sets one from a view
    /// of the top bar.
    public var chromiumSurfacePolicy: CefChromiumSurface.Policy {
        get { surfaces.policy }
        set { surfaces.policy = newValue }
    }

    /// Decides a surface's presentation as it appears, taking precedence
    /// over ``chromiumSurfacePolicy``; `nil` uses the policy.
    public var presentationForChromiumSurface: ((CefChromiumSurface) -> CefChromiumSurface.Presentation?)? {
        get { surfaces.presentationForChromiumSurface }
        set { surfaces.presentationForChromiumSurface = newValue }
    }

    /// Chromium's surfaces in this window, of every tab, oldest first.
    public var chromiumSurfaces: [CefChromiumSurface] { surfaces.surfaces }

    /// Called as each surface appears, whatever its presentation, as
    /// ``CefWindow/onChromiumSurface``.
    public var onChromiumSurface: ((CefChromiumSurface) -> Void)? {
        get { surfaces.onSurface }
        set { surfaces.onSurface = newValue }
    }

    /// Presents your own interface for a kind of surface, as
    /// ``CefWindow/setCustomPresentation(for:_:)``: `present` receives the
    /// surface, for the tab it is opened in, whenever Chromium would show
    /// it. Pass `nil` to go back to Chromium's.
    public func setCustomPresentation(
        for kind: CefChromiumSurface.Kind, _ present: (@MainActor (CefChromiumSurface) -> Void)?
    ) {
        surfaces.setCustomPresentation(for: kind, present)
    }

    /// The window's surface state, made on first use.
    var surfaces: ChromiumSurfaceController {
        if let surfaceController { return surfaceController }
        ChromiumSurfaces.activate()
        let made = ChromiumSurfaceController(host: self, policy: nil)
        surfaceController = made
        made.start()
        return made
    }
}

extension CefChromeWindow: ChromiumSurfaceHost {
    var surfaceNSWindow: NSWindow? { window }

    /// The browser whose page Chromium shows: the active tab's.
    var surfaceBrowser: CefBrowser? {
        if let page = window?.contentView.flatMap(ChromeWindowHost.page(in:)),
           let shown = CefRuntime.shared.browsers.first(where: { browser in
               guard let view = browser.nativeView else { return false }
               return view === page || view.isDescendant(of: page)
           }) {
            return shown
        }
        return activeTab?.browser
    }

    var isSurfaceHostClosed: Bool { isClosed }

    func withSurfaceNSWindow(_ body: @escaping @MainActor (NSWindow) -> Void) {
        if let window { return body(window) }
        whenAttached.append(body)
    }

    /// Bubbles that hang from Chrome's covered toolbar go under the app's
    /// top bar, at the page's trailing edge.
    func defaultSurfaceAnchor(for kind: CefChromiumSurface.Kind) -> CefChromiumSurface.Anchor? {
        guard !showsChromeUI, kind.hangsFromToolbar, let content = window?.contentView, contentFrame.width > 0 else { return nil }
        // contentFrame is from the content view's top left; anchors are in
        // window coordinates, from the bottom left.
        let top = content.frame.maxY - contentFrame.minY
        let rect = CGRect(x: content.frame.minX + contentFrame.minX + 8, y: top,
                          width: max(0, contentFrame.width - 16), height: 0)
        return .rect(rect, alignment: .trailing, spacing: 6)
    }
}
