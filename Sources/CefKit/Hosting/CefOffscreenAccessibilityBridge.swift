import AppKit

/// Connects a ``CefOffscreenPageView`` to its page's
/// ``CefAccessibilityTree``: keeps one element per node, turns the tree on
/// when an assistive app shows up, and posts AppKit notifications for
/// Chromium's changes.
@MainActor
final class CefOffscreenAccessibilityBridge {
    weak var view: CefOffscreenPageView?
    private var elements: [CefAccessibilityNode.ID: CefOffscreenAccessibilityElement] = [:]
    private var voiceOverObservation: NSKeyValueObservation?
    private nonisolated(unsafe) var applicationObserver: NSObjectProtocol?
    private var layoutNotificationPending = false
    private var rootID: CefAccessibilityNode.ID?

    init(view: CefOffscreenPageView) {
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

    /// The tree of the view's page, while it is being built.
    var tree: CefAccessibilityTree? {
        guard let page = view?.page, page.isAccessibilityEnabled else { return nil }
        return page.accessibilityTree
    }

    /// Asks the page for its tree when an assistive app is present.
    func requestTree() {
        view?.page?.requestAccessibilityTree()
    }

    /// Turns the tree on early when something already asked for it.
    func pageDidChange() {
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
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        guard view.bounds.contains(view.viewPoint(fromWindow: windowPoint)) else { return nil }
        return tree.hitTest(view.pagePoint(fromWindow: windowPoint)).map { element(for: $0.id) }
    }

    /// A rect in page points (top-left origin), in screen coordinates
    /// (bottom-left origin), as the view shows the page.
    func screenRect(forViewRect rect: CGRect) -> NSRect {
        view?.screenRect(fromPage: rect) ?? .zero
    }

    func perform(_ action: CefAccessibilityAction, on id: CefAccessibilityNode.ID) {
        guard let view, let page = view.page else { return }
        switch action {
        case .focus, .press, .increment, .decrement, .setValue:
            // The page takes focus only while its view is first responder.
            if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        case .scrollToVisible, .showMenu:
            break
        }
        Task { await page.performAccessibilityAction(action, on: id) }
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
            name: CefOffscreenPageView.didPostAccessibilityNotification, object: view,
            userInfo: [
                CefOffscreenPageView.accessibilityNotificationKey: notification,
                CefOffscreenPageView.accessibilityElementKey: element,
            ])
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
