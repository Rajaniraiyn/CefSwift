import AppKit
import CefKit

// The view is an `AXGroup` whose child is the page's `AXWebArea`. Chromium
// builds the page's tree only once an assistive app asks for it (see
// ``CefBrowserOptions/offscreenAccessibility``); until it arrives the group
// has no children.
extension CefOffscreenBrowserView {

    /// Posted on the main thread, with the view as the object, each time the
    /// view posts an accessibility notification for its page — for tests and
    /// diagnostics. `userInfo` holds the ``accessibilityNotificationKey``
    /// (an `NSAccessibility.Notification`) and the ``accessibilityElementKey``
    /// (the element it was posted for).
    public nonisolated static let didPostAccessibilityNotification = Notification.Name("CefOffscreenBrowserViewDidPostAccessibilityNotification")
    /// The `NSAccessibility.Notification` in a
    /// ``didPostAccessibilityNotification``.
    public nonisolated static let accessibilityNotificationKey = "notification"
    /// The element in a ``didPostAccessibilityNotification``.
    public nonisolated static let accessibilityElementKey = "element"

    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .group }

    public override func accessibilityLabel() -> String? { "Web content" }

    public override func accessibilityChildren() -> [Any]? {
        onMain {
            accessibilityBridge.requestTree()
            return accessibilityBridge.rootElement.map { [$0] } ?? []
        }
    }

    public override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        onMain {
            accessibilityBridge.requestTree()
            return accessibilityBridge.hitTest(screenPoint: point) ?? self
        }
    }

    public override var accessibilityFocusedUIElement: Any? {
        onMain {
            accessibilityBridge.requestTree()
            return accessibilityBridge.focusedElement ?? self
        }
    }

    public func offscreenAccessibilityTreeDidChange(_ changes: CefAccessibilityChanges) {
        accessibilityBridge.treeDidChange(changes)
    }
}

/// Connects a ``CefOffscreenBrowserView`` to its browser's
/// ``CefAccessibilityTree``: keeps one element per node, turns the tree on
/// when an assistive app shows up, and posts AppKit notifications for
/// Chromium's changes.
@MainActor
final class CefOffscreenAccessibilityBridge {
    weak var view: CefOffscreenBrowserView?
    private var elements: [CefAccessibilityNode.ID: CefOffscreenAccessibilityElement] = [:]
    private var voiceOverObservation: NSKeyValueObservation?
    private nonisolated(unsafe) var applicationObserver: NSObjectProtocol?
    private var layoutNotificationPending = false
    private var rootID: CefAccessibilityNode.ID?

    init(view: CefOffscreenBrowserView) {
        self.view = view
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if NSWorkspace.shared.isVoiceOverEnabled { self?.requestTree() }
                }
            }
        }
        applicationObserver = NotificationCenter.default.addObserver(
            forName: CefApplication.accessibilityRequestedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestTree() }
        }
    }

    deinit {
        if let applicationObserver { NotificationCenter.default.removeObserver(applicationObserver) }
    }

    /// The tree of the view's browser, while it is being built.
    var tree: CefAccessibilityTree? {
        guard let browser = view?.browser, browser.isAccessibilityEnabled else { return nil }
        return browser.accessibilityTree
    }

    /// Asks the browser for its tree when an assistive app is present.
    func requestTree() {
        view?.browser?.requestAccessibilityTree()
    }

    /// Turns the tree on early when something already asked for it.
    func browserDidChange() {
        let removed = elements.values
        elements = [:]
        rootID = nil
        for element in removed { post(element, .uiElementDestroyed) }
        if NSWorkspace.shared.isVoiceOverEnabled || CefApplication.isAccessibilityRequested {
            requestTree()
        }
    }

    func element(for id: CefAccessibilityNode.ID) -> CefOffscreenAccessibilityElement {
        if let element = elements[id] { return element }
        let element = CefOffscreenAccessibilityElement(nodeID: id, bridge: self)
        elements[id] = element
        return element
    }

    var rootElement: CefOffscreenAccessibilityElement? {
        tree?.root.map { element(for: $0.id) }
    }

    var focusedElement: CefOffscreenAccessibilityElement? {
        tree?.focusedNode.map { element(for: $0.id) }
    }

    func hitTest(screenPoint: NSPoint) -> Any? {
        guard let view, let window = view.window, let tree else { return nil }
        let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard view.bounds.contains(point) else { return nil }
        return tree.hitTest(point).map { element(for: $0.id) }
    }

    /// A rect in the view's coordinates (top-left origin), in screen
    /// coordinates (bottom-left origin).
    func screenRect(forViewRect rect: CGRect) -> NSRect {
        guard let view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    func perform(_ action: CefAccessibilityAction, on id: CefAccessibilityNode.ID) {
        guard let view, let browser = view.browser else { return }
        switch action {
        case .focus, .press, .increment, .decrement, .setValue:
            // The page takes focus only while its view is first responder.
            if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        case .scrollToVisible, .showMenu:
            break
        }
        Task { await browser.performAccessibilityAction(action, on: id) }
    }

    // MARK: Notifications

    func treeDidChange(_ changes: CefAccessibilityChanges) {
        guard let view else { return }
        for id in changes.removedNodes {
            if let element = elements.removeValue(forKey: id) { post(element, .uiElementDestroyed) }
        }
        guard let tree else {
            rootID = nil
            post(view, .layoutChanged)
            return
        }
        if tree.root?.id != rootID {
            rootID = tree.root?.id
            // A new document: assistive apps re-read the view's children.
            post(view, .layoutChanged)
        }
        func exposed(_ ids: Set<CefAccessibilityNode.ID>) -> [CefOffscreenAccessibilityElement] {
            ids.compactMap { id in tree.exposedNode(atOrAbove: id) }.map(\.id).uniqued().map { element(for: $0) }
        }
        for element in exposed(changes.valueChangedNodes) { post(element, .valueChanged) }
        for element in exposed(changes.selectedTextChangedNodes) { post(element, .selectedTextChanged) }
        for element in exposed(changes.selectedChildrenChangedNodes) { post(element, .selectedChildrenChanged) }
        if changes.focusDidChange, let focused = focusedElement {
            post(focused, .focusedUIElementChanged)
        }
        if changes.didFinishLoading, let root = rootElement {
            post(root, NSAccessibility.Notification(rawValue: "AXLoadComplete"))
        }
        for announcement in changes.announcements {
            let priority: NSAccessibilityPriorityLevel = announcement.isAssertive ? .high : .medium
            post(NSApp as Any, .announcementRequested, userInfo: [
                .announcement: announcement.text,
                .priority: priority.rawValue,
            ])
        }
        if changes.layoutDidChange { scheduleLayoutNotification() }
    }

    /// Chromium reports movement often, during scrolling and animation; one
    /// layout notification per tenth of a second is plenty.
    private func scheduleLayoutNotification() {
        guard !layoutNotificationPending else { return }
        layoutNotificationPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layoutNotificationPending = false
                if let root = self.rootElement { self.post(root, .layoutChanged) }
            }
        }
    }

    private func post(
        _ element: Any, _ notification: NSAccessibility.Notification,
        userInfo: [NSAccessibility.NotificationUserInfoKey: Any]? = nil
    ) {
        if let userInfo {
            NSAccessibility.post(element: element, notification: notification, userInfo: userInfo)
        } else {
            NSAccessibility.post(element: element, notification: notification)
        }
        NotificationCenter.default.post(
            name: CefOffscreenBrowserView.didPostAccessibilityNotification, object: view,
            userInfo: [
                CefOffscreenBrowserView.accessibilityNotificationKey: notification,
                CefOffscreenBrowserView.accessibilityElementKey: element,
            ])
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
