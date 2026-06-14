import AppKit
import CefKit
import SwiftUI

/// A SwiftUI view that displays a CEF (Chromium) browser.
///
/// Use the ``init(url:)`` convenience for a self-contained web view, or drive the view with a
/// shared ``CefWebViewModel`` for full control over navigation and observable state:
///
/// ```swift
/// // Simple:
/// CefWebView(url: URL(string: "https://example.com")!)
///
/// // Full control:
/// @State private var model = CefWebViewModel(url: homeURL)
/// CefWebView(model: model)
/// ```
///
/// The underlying CEF browser is created lazily the first time the view lands in a window
/// (CEF windowed browsers need a parent `NSView` inside a window), tracks the view's bounds,
/// and is closed when SwiftUI dismantles the view.
public struct CefWebView: NSViewRepresentable {

    private let externalModel: CefWebViewModel?
    private let initialURL: URL?

    /// Creates a web view driven by the given model.
    /// - Parameter model: The model whose browser this view hosts and displays.
    public init(model: CefWebViewModel) {
        self.externalModel = model
        self.initialURL = nil
    }

    /// Creates a self-contained web view that loads `url`, owning a private model.
    /// - Parameter url: The URL to load.
    public init(url: URL) {
        self.externalModel = nil
        self.initialURL = url
    }

    // MARK: NSViewRepresentable

    public func makeCoordinator() -> Coordinator {
        // The coordinator owns the private model for `init(url:)` so the model (and its
        // browser) survives SwiftUI re-creating the `CefWebView` value on every render.
        Coordinator(model: externalModel ?? CefWebViewModel(url: initialURL))
    }

    public func makeNSView(context: Context) -> CefBrowserHostView {
        let view = CefBrowserHostView()
        view.model = context.coordinator.model
        return view
    }

    public func updateNSView(_ nsView: CefBrowserHostView, context: Context) {
        // If the caller swapped in a different model instance, rebind the host view
        // (closes the old model's browser and creates one for the new model).
        if let externalModel, externalModel !== context.coordinator.model {
            context.coordinator.model = externalModel
        }
        nsView.model = context.coordinator.model
    }

    public static func dismantleNSView(_ nsView: CefBrowserHostView, coordinator: Coordinator) {
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

// MARK: - Hosting NSView

/// The `NSView` that hosts the CEF-created browser view.
///
/// Creates the browser the first time the view is attached to a window, keeps the CEF child
/// view sized to its bounds, and survives being removed from and re-added to a window.
@MainActor public final class CefBrowserHostView: NSView {

    /// The model whose browser this view hosts. Setting a different model closes the
    /// previously hosted browser and (when possible) creates one for the new model.
    var model: CefWebViewModel? {
        didSet {
            guard model !== oldValue else { return }
            if let oldValue {
                closeBrowser(of: oldValue)
            }
            adoptOrCreateBrowserIfPossible()
        }
    }

    /// Set during teardown so a late `viewDidMoveToWindow` can't resurrect the browser.
    private var isTornDown = false

    init() {
        super.init(frame: .zero)
        autoresizesSubviews = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // This view is created programmatically by CefWebView only.
        return nil
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // CEF windowed browsers require a parent view in a window: this is the earliest
        // reliable creation point. Re-entry on subsequent appearances is a no-op when the
        // model already has a live browser.
        adoptOrCreateBrowserIfPossible()
    }

    public override func layout() {
        super.layout()
        resizeBrowserView()
    }

    // MARK: Browser lifecycle

    private func adoptOrCreateBrowserIfPossible() {
        guard !isTornDown, window != nil, let model else { return }

        if let existing = model.browser {
            // The model already has a browser (view re-created, or model shared with a
            // previous host). Adopt its native view into our hierarchy if needed.
            if let native = existing.nativeView, native.superview !== self {
                native.removeFromSuperview()
                addSubview(native)
                configure(browserView: native)
            }
            return
        }

        let url = model.url ?? URL(string: "about:blank") ?? URL(fileURLWithPath: "/")
        let browser = CefBrowser.createBrowser(
            parentView: self,
            bounds: bounds,
            url: url,
            options: model.options,
            delegate: model
        )
        model.attach(browser)
        if let native = browser.nativeView {
            configure(browserView: native)
        }
    }

    private func configure(browserView: NSView) {
        browserView.frame = bounds
        browserView.autoresizingMask = [.width, .height]
    }

    private func resizeBrowserView() {
        guard let native = model?.browser?.nativeView, native.superview === self else { return }
        if native.frame != bounds {
            native.frame = bounds
        }
        if native.autoresizingMask != [.width, .height] {
            native.autoresizingMask = [.width, .height]
        }
    }

    private func closeBrowser(of model: CefWebViewModel) {
        guard let browser = model.browser else { return }
        // Only close browsers actually hosted by this view.
        guard let native = browser.nativeView, native.superview === self || native.superview == nil else { return }
        model.detach()
        // Force-close: the hosting view is going away, so JS onbeforeunload prompts
        // can't meaningfully be shown.
        browser.close(force: true)
    }

    /// Closes the hosted browser and detaches the model. Called on dismantle.
    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        if let model {
            closeBrowser(of: model)
        }
        model = nil
    }
}
