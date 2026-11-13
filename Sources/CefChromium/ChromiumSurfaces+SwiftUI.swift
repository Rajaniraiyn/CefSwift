import AppKit
import CefKit
import SwiftUI

extension CefBrowserWindow {
    /// Replaces one of Chromium's surfaces with a SwiftUI view, shown in a
    /// panel under the kind's anchor (``CefBrowserWindow/ChromiumUI/anchors``, or
    /// ``CefBrowserWindow/ChromiumUI/anchor`` for surfaces that hang from the toolbar), or
    /// at the top right of the page. The panel closes when the surface is
    /// dismissed (``CefChromiumSurface/dismiss()``), on Esc, and on a click
    /// elsewhere.
    ///
    /// ```swift
    /// window.setCustomPresentation(for: .qrCode) { surface in
    ///     MyQRCodeView(url: surface.url)
    ///         .padding()
    /// }
    /// ```
    ///
    /// The view is drawn on a plain rounded background; give it its own
    /// padding.
    public func setCustomPresentation(
        for kind: CefChromiumSurface.Kind, @ViewBuilder content: @escaping (CefChromiumSurface) -> some View
    ) {
        setCustomPresentation(for: kind) { surface in
            SurfacePanel.present(surface, content: AnyView(content(surface)))
        }
    }

    /// Replaces Chromium's find bar with a SwiftUI view, shown under the
    /// toolbar while the browser's ``CefBrowser/findSession`` is active: from
    /// ⌘F or ``CefChromeCommand/find`` until ``CefFindSession/end()``.
    ///
    /// ```swift
    /// window.setFindBar { session in FindBar(session: session) }
    /// ```
    ///
    /// The bar's first text field takes keyboard focus as it appears.
    public func setFindBar(@ViewBuilder _ content: @escaping (CefFindSession) -> some View) {
        let session = browser.findSession
        let accessory = FindBarAccessory(session: session, content: AnyView(content(session)))
        withWindow { window in
            accessory.install(in: window)
        }
        // The window keeps the accessory through its presenter.
        setCustomPresentation(for: .findBar) { surface in
            accessory.show(for: surface)
        }
    }

    /// Replaces Chromium's status bubble — the address of a hovered link —
    /// with a SwiftUI view laid over the page (``statusBubbleView``). `content` receives
    /// ``CefBrowser/statusText`` as it changes, and is shown only while it
    /// is not empty; align it within the page yourself.
    ///
    /// ```swift
    /// window.setStatusBubble { text in
    ///     Text(text)
    ///         .padding(6)
    ///         .background(.regularMaterial, in: .rect(cornerRadius: 6))
    ///         .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    ///         .padding(8)
    /// }
    /// ```
    public func setStatusBubble(@ViewBuilder _ content: @escaping (String) -> some View) {
        let hosting = NSHostingView(rootView: StatusTextReader(browser: browser, content: { AnyView(content($0)) }))
        statusBubbleView = PassthroughHostingContainer(hosting)
    }
}

/// Reads the status text in `body`, so SwiftUI redraws as it changes.
private struct StatusTextReader: View {
    let browser: CefBrowser
    let content: (String) -> AnyView

    var body: some View {
        let text = browser.statusText
        ZStack {
            if !text.isEmpty { content(text) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// Holds a hosting view and lets every event through to the page.
private final class PassthroughHostingContainer: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Surface anchors

extension View {
    /// Makes this view the anchor of Chromium's surfaces in the
    /// ``CefBrowserWindow`` it is in, such as a view of the window's
    /// toolbar: Chromium's bubbles appear beneath it instead of where
    /// Chrome's toolbar would be.
    ///
    /// Without `kinds`, the view becomes the window's
    /// ``CefBrowserWindow/ChromiumUI/anchor``, which every surface that hangs from Chrome's
    /// toolbar follows; with them, it is the anchor of those kinds in
    /// ``CefBrowserWindow/ChromiumUI/anchors``, Chromium's surfaces and your own interface
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
        alignment: CefChromiumSurface.Anchor.Alignment = .center,
        spacing: CGFloat = 4
    ) -> some View {
        background(SurfaceAnchorRepresentable(kinds: kinds, alignment: alignment, spacing: spacing))
    }
}

private struct SurfaceAnchorRepresentable: NSViewRepresentable {
    let kinds: Set<CefChromiumSurface.Kind>?
    let alignment: CefChromiumSurface.Anchor.Alignment
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
    private var alignment = CefChromiumSurface.Anchor.Alignment.center
    private var spacing: CGFloat = 4
    private weak var registeredWindow: CefBrowserWindow?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Called from `updateNSView`, where SwiftUI tracks what is read: the
    /// window's `chromiumUI` is touched only when something changed, and
    /// outside the update, so writing it does not start another update.
    func configure(kinds: Set<CefChromiumSurface.Kind>?, alignment: CefChromiumSurface.Anchor.Alignment, spacing: CGFloat) {
        guard kinds != self.kinds || alignment != self.alignment || spacing != self.spacing || !isConfigured else { return }
        isConfigured = true
        self.kinds = kinds
        self.alignment = alignment
        self.spacing = spacing
        DispatchQueue.main.async { [weak self] in
            self?.unregister()
            self?.register()
        }
    }

    private var isConfigured = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.unregister()
            self?.register()
        }
    }

    private func register() {
        guard let window, let owner = CefBrowserWindow.owning(window) else { return }
        let anchor = CefChromiumSurface.Anchor.view(self, alignment: alignment, spacing: spacing)
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
        // Wherever this view anchors, whatever kinds it was set up with.
        for (kind, anchor) in owner.chromiumUI.anchors where anchor.isAnchored(to: self) {
            owner.chromiumUI.anchors[kind] = nil
        }
        if owner.chromiumUI.anchor?.isAnchored(to: self) == true {
            owner.chromiumUI.anchor = nil
        }
    }
}

// MARK: - Panel for custom surfaces

/// A borderless panel that shows a custom surface over the browser window
/// and closes with it.
@MainActor
private final class SurfacePanel: NSPanel {
    private weak var surface: CefChromiumSurface?
    private var clickMonitor: Any?

    static func present(_ surface: CefChromiumSurface, content: AnyView) {
        guard let parent = surface.browserWindow?.window else { return }
        let panel = SurfacePanel(surface: surface, content: content)
        parent.addChildWindow(panel, ordered: .above)
        surface.position(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.followDismissal()
    }

    private init(surface: CefChromiumSurface, content: AnyView) {
        self.surface = surface
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5) })
        hosting.sizingOptions = [.intrinsicContentSize]
        contentView = hosting
        setContentSize(hosting.fittingSize)
        // A click outside the panel dismisses it, as with Chromium's bubbles.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                if let self, event.window !== self { self.surface?.dismiss() }
            }
            return event
        }
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        surface?.dismiss()
    }

    /// Closes the panel once the surface is dismissed.
    private func followDismissal() {
        guard let surface, surface.isPresented else {
            closePanel()
            return
        }
        withObservationTracking {
            _ = surface.isPresented
        } onChange: { [weak self] in
            Task { @MainActor in self?.followDismissal() }
        }
    }

    private func closePanel() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

// MARK: - Find bar

/// Shows the app's find bar as a title-bar accessory under the toolbar,
/// as Safari does, while the find session is active.
@MainActor
private final class FindBarAccessory {
    private let session: CefFindSession
    private let controller = NSTitlebarAccessoryViewController()
    private let hosting: NSHostingView<AnyView>
    private weak var surface: CefChromiumSurface?

    init(session: CefFindSession, content: AnyView) {
        self.session = session
        hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.intrinsicContentSize]
        controller.view = hosting
        controller.layoutAttribute = .bottom
        controller.isHidden = true
    }

    func install(in window: NSWindow) {
        guard controller.parent == nil else { return }
        window.addTitlebarAccessoryViewController(controller)
        follow()
    }

    func show(for surface: CefChromiumSurface) {
        self.surface = surface
        update()
    }

    /// Shows the bar while the session is active; dismisses the surface
    /// when it ends.
    private func follow() {
        let isActive = withObservationTracking {
            session.isActive
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        _ = isActive
        update()
    }

    private func update() {
        let isActive = session.isActive
        guard controller.isHidden == isActive else { return }
        if isActive {
            // Title-bar accessories take their height from the view's frame.
            hosting.setFrameSize(NSSize(width: hosting.frame.width, height: hosting.fittingSize.height))
        }
        controller.isHidden = !isActive
        if isActive {
            // SwiftUI focus does not reach title-bar accessories; focus the
            // field directly.
            DispatchQueue.main.async { [hosting] in
                if let field = Self.firstTextField(in: hosting) { hosting.window?.makeFirstResponder(field) }
            }
        } else {
            surface?.dismiss()
            surface = nil
        }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable { return field }
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }
}
