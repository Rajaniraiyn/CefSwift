import AppKit
import CefSwiftUI

/// Shows the popups a page opens (sign-in windows, `window.open` with
/// features) as panels layered over the window that opened them: at the
/// size the page asked for, centered over the page, moving with the window,
/// and closed along with it.
@MainActor
enum PopupPresenter {
    static func hostPopups(of window: CefWindow, controller: BrowserController) {
        window.onPopup = { [weak window, weak controller] popup in
            guard let window, let controller else { return }
            present(popup, over: window, controller: controller)
        }
    }

    /// The size of a popup's page: the size it asked for, or 520 × 640,
    /// within the opener's page less a margin.
    static func pageSize(requested: CGSize, available: CGSize) -> CGSize {
        CGSize(
            width: min(requested.width > 0 ? requested.width : 520, available.width - 48),
            height: min(requested.height > 0 ? requested.height : 640, available.height - 48))
    }

    private static func present(_ popup: CefWindow, over opener: CefWindow, controller: BrowserController) {
        guard let parent = opener.window, let panel = popup.window else {
            popup.show()
            return
        }
        // Popups get what the features add to every window, popups of
        // popups included.
        controller.windowDidOpen(popup)
        panel.tabbingMode = .disallowed
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let pageSize = pageSize(
            requested: popup.browser.popupFeatures?.size ?? .zero, available: parent.contentLayoutRect.size)
        var frame = panel.frameRect(forContentRect: CGRect(origin: .zero, size: pageSize))
        let page = parent.convertToScreen(parent.contentLayoutRect)
        frame.origin = CGPoint(x: page.midX - frame.width / 2, y: page.midY - frame.height / 2)
        panel.setFrame(frame, display: false)
        parent.addChildWindow(panel, ordered: .above)

        // Closing the opener closes its popups; a closed popup leaves its
        // parent's child windows.
        let closeWithOpener = opener.onClose
        opener.onClose = { [weak popup] in
            closeWithOpener?()
            popup?.close()
        }
        popup.onClose = { [weak parent, weak panel] in
            if let panel { parent?.removeChildWindow(panel) }
        }
        showSite(of: popup)
        popup.show()
    }

    /// Keeps the site a popup shows in its title bar, as browsers must: a
    /// sign-in popup's page could claim to be anyone.
    private static func showSite(of popup: CefWindow) {
        guard !popup.isClosed else { return }
        let host = withObservationTracking {
            popup.browser.url?.host()
        } onChange: { [weak popup] in
            Task { @MainActor in popup.map(showSite(of:)) }
        }
        popup.window?.subtitle = host ?? ""
    }
}
