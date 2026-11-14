import AppKit
import CefKit
import ObjectiveC

// How a CefChromeWindow leaves Chrome's tab strip and toolbar to the app.
//
// Chromium lays out its window in views (`BrowserView`) and draws it in one
// layer inside `BridgedContentView`, the window's content view; the page is
// the active tab's `WebContentsViewCocoa`, a subview of it. Nothing in CEF or
// Chromium's preferences takes the tab strip and toolbar out of a normal
// window (popup and app windows have none, but are not tabbed), so the app's
// views go over them: a view in the window's frame view, above the content
// view (which answers every hit test inside itself) and below the title bar
// (whose window buttons stay on top). Under it, Chrome's controls are kept
// out of the way: no clicks reach them; their accessibility elements are
// left out of Chromium's accessibility tree (AXPlatformNodeCocoa's
// children); and keyboard focus that lands on them moves on to the app's
// views. All three use only AppKit's public interfaces on Chromium's
// classes, by name, and do nothing if the names change.

/// Covers Chrome's tab strip and toolbar in one window.
@MainActor
final class ChromeWindowHost {
    private weak var window: CefChromeWindow?
    private weak var nsWindow: NSWindow?
    private let cover = ChromeUICoverView()
    private var observers: [NSObjectProtocol] = []
    private var responderObservation: NSKeyValueObservation?
    private weak var observedPage: NSView?
    private var isMovingFocus = false

    init(window: CefChromeWindow, nsWindow: NSWindow) {
        self.window = window
        self.nsWindow = nsWindow
        let center = NotificationCenter.default
        for name in [NSWindow.didUpdateNotification, NSWindow.didResizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: nsWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        responderObservation = nsWindow.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged() }
        }
        ChromeAccessibilityFilter.install()
    }

    func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        responderObservation = nil
        cover.removeFromSuperview()
        ChromeAccessibilityFilter.coveredWindows.removeAll { $0.window == nil || $0.window === nsWindow }
    }

    /// The active tab's page: the content view's `WebContentsViewCocoa`
    /// that is shown.
    static func page(in contentView: NSView) -> NSView? {
        contentView.subviews.last { !$0.isHidden && "\(type(of: $0))" == "WebContentsViewCocoa" }
    }

    /// Runs `body` with the app's views out of the way of events, for
    /// events CefChromium sends to Chrome's covered controls.
    func withCoverSetAside(_ body: () -> Void) {
        let wasHidden = cover.isHidden
        cover.isHidden = true
        body()
        cover.isHidden = wasHidden
    }

    /// Lays the app's views out again where Chrome's are now.
    func update() {
        guard let window, let nsWindow, let contentView = nsWindow.contentView, let frameView = contentView.superview else { return }
        guard let page = Self.page(in: contentView) else { return }
        if observedPage !== page {
            observedPage = page
            page.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: page, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        // In the content view's coordinates, from its top left.
        let pageInContent = contentView.convert(page.bounds, from: page)
        let height = contentView.bounds.height
        let pageRect = contentView.isFlipped
            ? pageInContent
            : CGRect(x: pageInContent.minX, y: height - pageInContent.maxY, width: pageInContent.width, height: pageInContent.height)
        let isRightToLeft = nsWindow.windowTitlebarLayoutDirection == .rightToLeft
        let top = max(0, pageRect.minY)
        let leading = isRightToLeft ? max(0, contentView.bounds.width - pageRect.maxX) : max(0, pageRect.minX)
        // Chrome's vertical tabs are at the leading edge; the side panel,
        // at the trailing edge, stays Chromium's.
        let sidebarWidth = Self.isVertical(window.strip.layout) ? leading : 0
        if window.contentFrame != pageRect { window.contentFrame = pageRect }
        if window.topBarHeight != top { window.topBarHeight = top }
        if window.sidebarWidth != sidebarWidth { window.sidebarWidth = sidebarWidth }

        let covers = !window.showsChromeUI
        if covers {
            if cover.superview !== frameView {
                frameView.addSubview(cover, positioned: .above, relativeTo: contentView)
            }
            cover.frame = contentView.frame
            cover.autoresizingMask = [.width, .height]
            cover.layout(topHeight: top, sidebarWidth: sidebarWidth, pageRect: pageRect, isRightToLeft: isRightToLeft,
                         topBar: window.topBar, sidebar: window.sidebar, overlay: window.pageOverlay)
            ChromeAccessibilityFilter.cover(nsWindow, rects: cover.coveredScreenRects())
            // Chromium moves focus between its own views without AppKit's
            // first responder changing, so look after each update too.
            firstResponderChanged()
        } else {
            if cover.superview != nil { cover.removeFromSuperview() }
            ChromeAccessibilityFilter.coveredWindows.removeAll { $0.window === nsWindow }
            if let overlay = window.pageOverlay {
                // Over the page, even with Chrome's own UI.
                if cover.superview !== frameView { frameView.addSubview(cover, positioned: .above, relativeTo: contentView) }
                cover.frame = contentView.frame
                cover.layout(topHeight: 0, sidebarWidth: 0, pageRect: pageRect, isRightToLeft: isRightToLeft,
                             topBar: nil, sidebar: nil, overlay: overlay)
            }
        }
    }

    private static func isVertical(_ layout: CefTabStrip.Layout) -> Bool {
        if case .vertical = layout { return true }
        return false
    }

    /// Keyboard focus that reaches Chrome's covered controls — Tab past a
    /// page's last link, F6, Chrome's focus shortcuts — moves to the app's
    /// top bar instead (or back to the page when the top bar takes none).
    private func firstResponderChanged() {
        guard !ChromeTabStripAccessibility.isWorkingStrip,
              let window, !window.showsChromeUI, let nsWindow, let contentView = nsWindow.contentView,
              nsWindow.firstResponder === contentView
        else { return }
        // Which of Chromium's views has focus, through its accessibility.
        guard let focused = contentView.accessibilityFocusedUIElement as AnyObject?,
              focused !== contentView,
              let frame = (focused as? NSAccessibilityElementProtocol)?.accessibilityFrame()
                ?? (focused.accessibilityFrame?() as CGRect?)
        else { return }
        let covered = cover.coveredScreenRects()
        guard covered.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(frame) }), !isMovingFocus else { return }
        isMovingFocus = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.moveFocusOutOfChrome()
                self?.isMovingFocus = false
            }
        }
    }

    private func moveFocusOutOfChrome() {
        guard let nsWindow, let window else { return }
        if let first = [window.topBar, window.sidebar].compactMap({ $0 }).lazy.compactMap(Self.firstKeyView(in:)).first {
            nsWindow.makeFirstResponder(first)
        } else if let page = window.activeTab?.browser?.nativeView, let target = Self.firstKeyView(in: page) {
            nsWindow.makeFirstResponder(target)
        }
    }

    private static func firstKeyView(in view: NSView) -> NSView? {
        if view.canBecomeKeyView, view.acceptsFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstKeyView(in: subview) { return found }
        }
        return nil
    }
}

/// The app's views over Chrome's: the top bar, the sidebar, the page
/// overlay. Events outside the covered areas pass to Chromium beneath.
final class ChromeUICoverView: NSView {
    private let background = NSView()
    private var topRect = CGRect.zero
    private var sideRect = CGRect.zero
    private let overlayContainer = PassthroughView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        background.wantsLayer = true
        addSubview(background)
        addSubview(overlayContainer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func layout(topHeight: CGFloat, sidebarWidth: CGFloat, pageRect: CGRect, isRightToLeft: Bool,
                topBar: NSView?, sidebar: NSView?, overlay: NSView?) {
        topRect = CGRect(x: 0, y: 0, width: bounds.width, height: topHeight)
        sideRect = CGRect(x: isRightToLeft ? bounds.width - sidebarWidth : 0, y: topHeight,
                          width: sidebarWidth, height: max(0, bounds.height - topHeight))
        background.frame = topRect.union(sideRect)
        background.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        background.isHidden = topHeight == 0 && sidebarWidth == 0
        place(topBar, in: topRect)
        place(sidebar, in: sideRect)
        overlayContainer.frame = pageRect
        if let overlay {
            if overlay.superview !== overlayContainer {
                overlayContainer.subviews.forEach { $0.removeFromSuperview() }
                overlayContainer.addSubview(overlay)
            }
            overlay.frame = overlayContainer.bounds
            overlay.autoresizingMask = [.width, .height]
        } else {
            overlayContainer.subviews.forEach { $0.removeFromSuperview() }
        }
    }

    private func place(_ view: NSView?, in rect: CGRect) {
        guard let view else { return }
        if view.superview !== self { addSubview(view, positioned: .below, relativeTo: overlayContainer) }
        view.frame = rect
        view.isHidden = rect.width < 1 || rect.height < 1
    }

    /// The covered areas, in screen coordinates.
    func coveredScreenRects() -> [CGRect] {
        guard let window else { return [] }
        return [topRect, sideRect].filter { $0.width > 0 && $0.height > 0 }.map {
            window.convertToScreen(convert($0, to: nil))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard topRect.contains(local) || sideRect.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func accessibilityChildren() -> [Any]? {
        subviews.filter { !$0.isHidden && $0 !== background && $0 !== overlayContainer }
    }
}

/// Carries AppKit objects across an isolation check made on the main thread.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A view that never takes an event.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Accessibility

/// Leaves Chrome's covered controls out of Chromium's accessibility tree:
/// an element of a covered window lying wholly under the app's views is not
/// listed among its parent's children, so VoiceOver and other assistive
/// apps see the app's controls there and never Chrome's.
@MainActor
enum ChromeAccessibilityFilter {
    struct Covered {
        weak var window: NSWindow?
        var rects: [CGRect]
    }

    static var coveredWindows: [Covered] = []
    /// While set, CefChromium itself reads the whole tree.
    static var isBypassed = false
    private static var isInstalled = false

    static func cover(_ window: NSWindow, rects: [CGRect]) {
        coveredWindows.removeAll { $0.window == nil || $0.window === window }
        coveredWindows.append(Covered(window: window, rects: rects))
    }

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        guard let nodeClass = NSClassFromString("AXPlatformNodeCocoa") else { return }
        for name in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder", "accessibilityVisibleChildren"] {
            replaceChildren(of: nodeClass, selector: NSSelectorFromString(name))
        }
    }

    private static func replaceChildren(of nodeClass: AnyClass, selector: Selector) {
        // Only a method the class itself defines: one it inherits is its
        // superclass's, shared with every other class.
        guard let method = class_getInstanceMethod(nodeClass, selector),
              method != class_getSuperclass(nodeClass).flatMap({ class_getInstanceMethod($0, selector) }),
              method_getTypeEncoding(method).map({ String(cString: $0) })?.hasPrefix("@") == true
        else { return }
        typealias Original = @convention(c) (AnyObject, Selector) -> NSArray?
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject) -> NSArray? = { node in
            let children = original(node, selector)
            guard let children, children.count > 0, Thread.isMainThread else { return children }
            let box = UncheckedBox((children, node))
            return MainActor.assumeIsolated { UncheckedBox(filter(box.value.0, of: box.value.1)) }.value
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    private static func filter(_ children: NSArray, of node: AnyObject) -> NSArray {
        guard !isBypassed, !coveredWindows.isEmpty else { return children }
        coveredWindows.removeAll { $0.window == nil }
        guard let covered = coveredWindows.first(where: { entry in
            guard let window = entry.window else { return false }
            return Self.window(of: node) === window
        }) else { return children }
        let kept = children.filter { child in
            guard let frame = (child as AnyObject).accessibilityFrame?() as CGRect?, frame.width > 0, frame.height > 0 else { return true }
            return !covered.rects.contains { $0.insetBy(dx: -1, dy: -1).contains(frame) }
        }
        return kept as NSArray
    }

    /// The window an accessibility element of Chromium's is in.
    private static func window(of node: AnyObject) -> NSWindow? {
        var current: AnyObject? = node
        for _ in 0..<40 {
            guard let element = current else { return nil }
            if let view = element as? NSView { return view.window }
            if let window = element as? NSWindow { return window }
            current = element.accessibilityParent?() as AnyObject?
        }
        return nil
    }

    /// Every element under `element`, depth first, CefChromium's own walk:
    /// the filter does not apply.
    static func descendants(of element: AnyObject, depth: Int = 0, limit: Int = 12) -> [AnyObject] {
        guard depth < limit else { return [] }
        let wasBypassed = isBypassed
        isBypassed = true
        defer { isBypassed = wasBypassed }
        let children = (element.accessibilityChildren?() ?? nil) ?? []
        var all: [AnyObject] = []
        for child in children {
            let object = child as AnyObject
            all.append(object)
            if (object.accessibilityRole?() ?? nil)?.rawValue == "AXWebArea" { continue }
            all += descendants(of: object, depth: depth + 1, limit: limit)
        }
        return all
    }
}
