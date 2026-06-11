import AppKit
import CefKit
import SwiftUI

/// **Experimental.** A SwiftUI view that embeds a *chrome-style* browser —
/// the full Chrome runtime (`chrome://history`, `chrome://extensions`,
/// `chrome://settings`, extension installs, profiles) with Chrome's own
/// toolbar/tab UI hidden — visually inside your layout.
///
/// CEF only supports Chrome style for windows it creates itself, so this view
/// uses a **child-window overlay**: a frameless CEF-created `NSWindow` is
/// attached to the hosting window with `addChildWindow(_:ordered:)` and kept
/// frame-synced to this view's bounds. The technique is used in production by
/// other CEF embedders, but it is an overlay, not a subview:
///
/// - The browser draws **above all sibling SwiftUI/AppKit content** in the
///   same region (don't place native overlays over it; popovers and sheets
///   from *other* windows are fine).
/// - macOS Spaces/fullscreen transitions and window-dragging previews can
///   briefly show the overlay detached.
/// - The overlay window can become key when clicked; focus generally behaves,
///   but it is a separate window to AppKit.
///
/// For ordinary embedded content prefer ``CefWebView`` (Alloy style); for a
/// standalone Chrome-style window prefer `CefChromeBrowser`.
///
/// Why not re-parent the CEF window's NSView into the hosting view instead?
/// Tested empirically (CEF 148): moving the views-hosted browser's
/// `get_window_handle` NSView into another window doesn't crash, but the
/// browser stops rendering entirely (the Views widget's compositor is bound
/// to the CEF-created NSWindow). The child-window overlay is the only
/// approach that keeps Chrome style rendering inside another app's window.
///
/// ```swift
/// CefChromeWebView(url: URL(string: "chrome://history")!)
/// ```
public struct CefChromeWebView: NSViewRepresentable {

    private let externalModel: CefWebViewModel?
    private let initialURL: URL?
    private let showsChromeToolbar: Bool

    /// Creates a chrome-style web view driven by the given model.
    /// - Parameters:
    ///   - model: The model whose browser this view hosts and displays.
    ///   - showsChromeToolbar: Shows Chrome's toolbar inside the overlay
    ///     (default `false`, i.e. web content only).
    public init(model: CefWebViewModel, showsChromeToolbar: Bool = false) {
        self.externalModel = model
        self.initialURL = nil
        self.showsChromeToolbar = showsChromeToolbar
    }

    /// Creates a self-contained chrome-style web view that loads `url`.
    public init(url: URL, showsChromeToolbar: Bool = false) {
        self.externalModel = nil
        self.initialURL = url
        self.showsChromeToolbar = showsChromeToolbar
    }

    // MARK: NSViewRepresentable

    public func makeCoordinator() -> Coordinator {
        Coordinator(model: externalModel ?? CefWebViewModel(url: initialURL))
    }

    public func makeNSView(context: Context) -> CefChromeOverlayHostView {
        let view = CefChromeOverlayHostView()
        view.showsChromeToolbar = showsChromeToolbar
        view.model = context.coordinator.model
        return view
    }

    public func updateNSView(_ nsView: CefChromeOverlayHostView, context: Context) {
        if let externalModel, externalModel !== context.coordinator.model {
            context.coordinator.model = externalModel
        }
        nsView.model = context.coordinator.model
    }

    public static func dismantleNSView(_ nsView: CefChromeOverlayHostView, coordinator: Coordinator) {
        nsView.tearDown()
    }

    /// Bridges the representable's lifetime to the (possibly view-owned) model.
    @MainActor public final class Coordinator {
        var model: CefWebViewModel

        init(model: CefWebViewModel) {
            self.model = model
        }
    }
}

// MARK: - Anchor NSView

/// The anchor view behind ``CefChromeWebView``: creates a frameless
/// `CefChromeBrowser`, attaches its NSWindow as a child window of the hosting
/// window, and keeps the overlay frame-synced to this view's screen rect.
@MainActor public final class CefChromeOverlayHostView: NSView {

    var showsChromeToolbar = false

    var model: CefWebViewModel? {
        didSet {
            guard model !== oldValue else { return }
            if oldValue != nil { closeOverlay() }
            createOverlayIfPossible()
        }
    }

    private var chrome: CefChromeBrowser?
    private var observedWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var isTornDown = false

    init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // Created programmatically by CefChromeWebView only.
        return nil
    }

    // MARK: Lifecycle hooks

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebindWindowObservers()
        createOverlayIfPossible()
        updateOverlay()
    }

    public override func layout() {
        super.layout()
        updateOverlay()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updateOverlay()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateOverlay()
    }

    // MARK: Overlay management

    private func createOverlayIfPossible() {
        guard !isTornDown, chrome == nil, let model, window != nil else { return }

        var options = CefChromeBrowserOptions()
        options.isFrameless = true
        options.showsChromeToolbar = showsChromeToolbar
        options.initialBounds = anchorScreenRect()

        let url = model.url ?? URL(string: "about:blank") ?? URL(fileURLWithPath: "/")
        let chrome = CefChromeBrowser.create(url: url, options: options, delegate: model)
        self.chrome = chrome
        model.attach(chrome.browser)

        chrome.onWindowDestroyed = { [weak self] in
            // Closed out from under us (window.close(), app teardown).
            guard let self else { return }
            self.chrome = nil
            self.model?.detach()
        }

        if let overlay = chrome.nsWindow {
            // Overlay etiquette: it's an implementation detail, not a window
            // the user manages.
            overlay.isExcludedFromWindowsMenu = true
            overlay.collectionBehavior.insert(.fullScreenAuxiliary)
        }
        updateOverlay()
    }

    /// Frame-syncs and shows/hides the overlay to match this view's state.
    private func updateOverlay() {
        guard let overlay = chrome?.nsWindow else { return }
        let visible =
            window != nil
            && !isHiddenOrHasHiddenAncestor
            && (window?.isVisible ?? false)
            && !(window?.isMiniaturized ?? true)
            && bounds.width > 1 && bounds.height > 1

        if visible, let window {
            if overlay.parent !== window {
                overlay.parent?.removeChildWindow(overlay)
                window.addChildWindow(overlay, ordered: .above)
            }
            let target = anchorScreenRect()
            if overlay.frame != target {
                overlay.setFrame(target, display: true)
            }
            overlay.orderFront(nil)
        } else {
            overlay.parent?.removeChildWindow(overlay)
            overlay.orderOut(nil)
        }
    }

    /// This view's bounds in AppKit screen coordinates.
    private func anchorScreenRect() -> CGRect {
        guard let window else { return CGRect(x: 200, y: 200, width: max(bounds.width, 200), height: max(bounds.height, 150)) }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    private func rebindWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
        observedWindow = window
        guard let window else { return }
        // Child windows move with the parent automatically; resize and
        // miniaturization still need explicit syncing.
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateOverlay()
                }
            }
            windowObservers.append(observer)
        }
    }

    private func closeOverlay() {
        guard let chrome else { return }
        chrome.onWindowDestroyed = nil
        if let overlay = chrome.nsWindow {
            overlay.parent?.removeChildWindow(overlay)
        }
        model?.detach()
        chrome.close()
        self.chrome = nil
    }

    /// Closes the overlay browser and detaches the model. Called on dismantle.
    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
        closeOverlay()
        model = nil
    }
}
