import CCef
import Foundation

/// When an offscreen browser builds its page's accessibility tree.
///
/// Chromium computes the tree in the renderer and sends every change to
/// the browser process, which costs CPU time and memory on every page, so
/// it is worth building only when something reads it. Windowed browsers
/// are unaffected: Chromium manages their accessibility itself.
public enum CefOffscreenAccessibility: Sendable, Equatable {
    /// Builds the tree on first demand: when VoiceOver is running, when an
    /// assistive app first asks the host view for its children, or when an
    /// app sets `AXEnhancedUserInterface` or `AXManualAccessibility` on the
    /// application, as Voice Control and automation tools do. Once on, it
    /// stays on for the browser's lifetime.
    case automatic
    /// Builds the tree from the moment the browser is created.
    case enabled
    /// Never builds the tree; the page is a single element to assistive
    /// technology.
    case disabled
}

/// An action an assistive app asks a page's node to perform.
public enum CefAccessibilityAction: Sendable, Equatable {
    /// Activates the node, as a click does.
    case press
    /// Moves keyboard focus to the node.
    case focus
    /// Scrolls the node into view.
    case scrollToVisible
    /// Opens the node's context menu.
    case showMenu
    /// Steps a slider or spin button up.
    case increment
    /// Steps a slider or spin button down.
    case decrement
    /// Replaces a text field's contents.
    case setValue(String)
}

extension CefBrowser {

    // MARK: State

    /// Turns the offscreen accessibility tree on or off, whatever
    /// ``CefBrowserOptions/offscreenAccessibility`` says. Before the browser
    /// is created, the choice applies at creation. Turning it off empties
    /// ``accessibilityTree``.
    public func setAccessibilityEnabled(_ enabled: Bool) {
        wantsAccessibility = enabled
        guard state == .live else { return }
        guard enabled != isAccessibilityEnabled else { return }
        isAccessibilityEnabled = enabled
        withHost { $0.pointee.set_accessibility_state($0, enabled ? STATE_ENABLED : STATE_DISABLED) }
        if !enabled {
            let changes = accessibilityTree.removeAll()
            if !changes.isEmpty { client?.offscreenHost?.offscreenAccessibilityTreeDidChange(changes) }
        }
    }

    /// Turns the offscreen accessibility tree on because an assistive app
    /// asked for it, unless ``CefBrowserOptions/offscreenAccessibility`` is
    /// `.disabled`. Hosts call this; `CefOffscreenBrowserView` does.
    public func requestAccessibilityTree() {
        guard options.offscreenAccessibility != .disabled, !isAccessibilityEnabled else { return }
        setAccessibilityEnabled(true)
    }

    /// At creation: applies ``CefBrowserOptions/offscreenAccessibility``
    /// or an earlier request.
    func applyInitialAccessibilityState() {
        guard client?.offscreenHost != nil else { return }
        if options.offscreenAccessibility == .enabled || wantsAccessibility {
            setAccessibilityEnabled(true)
        }
    }

    func accessibilityDidClose() {
        guard isAccessibilityEnabled || !accessibilityTree.isEmpty else { return }
        isAccessibilityEnabled = false
        let changes = accessibilityTree.removeAll()
        if !changes.isEmpty { client?.offscreenHost?.offscreenAccessibilityTreeDidChange(changes) }
    }

    /// A browser discarded by closing it empties its tree, and builds it
    /// again when it is created anew.
    func accessibilityDidCloseForDiscard() {
        isDevToolsAccessibilityEnabled = false
        guard isAccessibilityEnabled else { return }
        wantsAccessibility = true
        accessibilityDidClose()
    }

    /// Setting the state at creation does not take for a browser created
    /// again after a discard (in CEF 156), so it is set again when the
    /// restored page starts loading.
    func reassertAccessibilityState() {
        guard isAccessibilityEnabled else { return }
        withHost { $0.pointee.set_accessibility_state($0, STATE_ENABLED) }
    }

    // MARK: Updates from Chromium

    func accessibilityTreeDidChange(_ value: CefJSON) {
        guard isAccessibilityEnabled else { return }
        syncAccessibilityScale()
        let changes = accessibilityTree.applyTreeChange(value)
        if !changes.isEmpty { client?.offscreenHost?.offscreenAccessibilityTreeDidChange(changes) }
    }

    func accessibilityLocationsDidChange(_ value: CefJSON) {
        guard isAccessibilityEnabled else { return }
        syncAccessibilityScale()
        let changes = accessibilityTree.applyLocationChanges(value)
        if !changes.isEmpty { client?.offscreenHost?.offscreenAccessibilityTreeDidChange(changes) }
    }

    /// Chromium reports scrolling to accessibility clients in a form CEF
    /// does not pass on, so the document's scroll position comes from the
    /// render handler's `on_scroll_offset_changed`, which reports it in the
    /// same physical pixels as the tree.
    func accessibilityScrollOffsetDidChange(_ offset: CGPoint) {
        guard isAccessibilityEnabled, let host = client?.offscreenHost else { return }
        let changes = accessibilityTree.applyDocumentScroll(offset)
        if !changes.isEmpty { host.offscreenAccessibilityTreeDidChange(changes) }
    }

    /// Keeps the tree's pixel-to-point ratio in step with the host.
    func syncAccessibilityScale() {
        guard let host = client?.offscreenHost else { return }
        accessibilityTree.deviceScaleFactor = host.offscreenViewInfo.deviceScaleFactor
    }

    // MARK: Actions

    /// Performs an assistive app's action on a node of
    /// ``accessibilityTree``. Returns whether the action was carried out.
    ///
    /// Actions go through the same routes as the user's own input, so the
    /// page sees trusted events: ``CefAccessibilityAction/press`` and
    /// ``CefAccessibilityAction/showMenu`` click the node's centre,
    /// ``CefAccessibilityAction/increment`` and
    /// ``CefAccessibilityAction/decrement`` press the arrow keys, and
    /// ``CefAccessibilityAction/setValue(_:)`` selects the field's text and
    /// replaces it with the DevTools protocol's `Input.insertText`, as an
    /// input method would. Focusing and scrolling a node of the main frame use
    /// the DevTools protocol's `DOM.focus` and `DOM.scrollIntoViewIfNeeded`,
    /// on the DOM node that the `Accessibility` domain reports for the
    /// node's identifier; Chromium shares those identifiers between the
    /// tree and the protocol. Nodes inside frames are focused by clicking
    /// text fields, and must already be in view to be pressed.
    @discardableResult
    public func performAccessibilityAction(_ action: CefAccessibilityAction, on id: CefAccessibilityNode.ID) async -> Bool {
        guard state == .live, isAccessibilityEnabled, let node = accessibilityTree.node(id) else { return false }
        switch action {
        case .scrollToVisible:
            return await scrollAccessibilityNodeToVisible(node)
        case .press:
            guard let point = await visibleCenter(of: node) else { return false }
            click(at: point, button: .left)
            return true
        case .showMenu:
            guard let point = await visibleCenter(of: node) else { return false }
            click(at: point, button: .right)
            return true
        case .focus:
            return await focusAccessibilityNode(node)
        case .increment, .decrement:
            guard await focusAccessibilityNode(node) else { return false }
            let up = action == .increment
            let windowsKeyCode = up ? 0x26 : 0x28  // VK_UP, VK_DOWN
            let nativeKeyCode = up ? 126 : 125
            sendKeyEvent(CefKeyEvent(phase: .rawKeyDown, windowsKeyCode: windowsKeyCode, nativeKeyCode: nativeKeyCode))
            sendKeyEvent(CefKeyEvent(phase: .keyUp, windowsKeyCode: windowsKeyCode, nativeKeyCode: nativeKeyCode))
            return true
        case .setValue(let text):
            guard node.isEditable || node.isRichlyEditable, await focusAccessibilityNode(node) else { return false }
            selectAll()
            if text.isEmpty {
                deleteSelection()
                return true
            }
            // Inserted as an input method would, replacing the selection.
            return (try? await devTools.send("Input.insertText", ["text": .string(text)])) != nil
        }
    }

    /// The view size, in points, that nodes must lie in to be clicked.
    private var accessibilityViewBounds: CGRect {
        CGRect(origin: .zero, size: client?.offscreenHost?.offscreenViewInfo.size ?? .zero)
    }

    private func isInView(_ frame: CGRect?) -> Bool {
        guard let frame, frame.width > 0, frame.height > 0 else { return false }
        let bounds = accessibilityViewBounds
        return bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// The node's centre in view points, after scrolling it into view.
    private func visibleCenter(of node: CefAccessibilityNode) async -> CGPoint? {
        guard await scrollAccessibilityNodeToVisible(node), let frame = accessibilityTree.frame(of: node.id) else {
            return nil
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The DevTools protocol's `backendNodeId` for a node of the main
    /// frame: its parent's children, as the `Accessibility` domain lists
    /// them, carry their DOM nodes.
    private func backendNodeID(of node: CefAccessibilityNode) async -> Int? {
        if let domNodeID = node.domNodeID { return domNodeID }
        guard node.id.tree == accessibilityTree.mainTreeID else { return nil }
        do {
            if !isDevToolsAccessibilityEnabled {
                try await devTools.send("Accessibility.enable")
                isDevToolsAccessibilityEnabled = true
            }
            let nodes: CefJSON
            if let parent = node.parentID {
                nodes = try await devTools.send("Accessibility.getChildAXNodes", ["id": .string(String(parent.node))])["nodes"]
            } else {
                nodes = [try await devTools.send("Accessibility.getRootAXNode")["node"]]
            }
            let match = nodes.arrayValue?.first { $0["nodeId"].stringValue == String(node.id.node) }
            return match?["backendDOMNodeId"].intValue
        } catch {
            return nil
        }
    }

    private func scrollAccessibilityNodeToVisible(_ node: CefAccessibilityNode) async -> Bool {
        if isInView(accessibilityTree.frame(of: node.id)) { return true }
        guard let backendNodeID = await backendNodeID(of: node) else { return false }
        do {
            try await devTools.send("DOM.scrollIntoViewIfNeeded", ["backendNodeId": .number(Double(backendNodeID))])
        } catch {
            return false
        }
        // The scroll lands in the renderer asynchronously.
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if isInView(accessibilityTree.frame(of: node.id)) { return true }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return isInView(accessibilityTree.frame(of: node.id))
    }

    private func focusAccessibilityNode(_ node: CefAccessibilityNode) async -> Bool {
        hostViewDidBecomeKey()
        if accessibilityTree.focusedNode?.id == node.id { return true }
        if node.id.tree == accessibilityTree.mainTreeID {
            // The nearest focusable node at or above this one, in its frame.
            var target: CefAccessibilityNode? = node
            while let candidate = target, !candidate.isFocusable {
                target = candidate.parentID.flatMap { accessibilityTree.node($0) }
            }
            guard let target, let backendNodeID = await backendNodeID(of: target) else { return false }
            do {
                try await devTools.send("DOM.focus", ["backendNodeId": .number(Double(backendNodeID))])
                return true
            } catch {
                return false
            }
        }
        // Frames other than the main one are out of the DevTools session's
        // reach; a click focuses a text field without changing it.
        guard node.isEditable || node.isRichlyEditable, let point = await visibleCenter(of: node) else { return false }
        click(at: point, button: .left)
        return true
    }

    private func click(at point: CGPoint, button: CefMouseButton) {
        sendMouseMove(to: point)
        sendMouseDown(at: point, button: button, clickCount: 1)
        sendMouseUp(at: point, button: button, clickCount: 1)
    }
}
